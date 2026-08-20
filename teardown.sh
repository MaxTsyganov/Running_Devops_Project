#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/output.sh"

echo -e "${BOLD}=================================================================="
echo "  DevOps App - Full Teardown"
echo "  This deletes Kubernetes workloads, Jenkins, the EKS cluster, and every"
echo "  Terraform-managed AWS resource (RDS, S3, SNS, ECR, IAM, networking)."
echo -e "==================================================================${RESET}"

step "[1/8] Deleting the app namespace..."
# Assignment 3 deployed via ArgoCD (an Application with a resources-
# finalizer, so deleting it cascades to everything it manages). Assignment 4
# replaced that with Jenkins CD deploying straight via helm upgrade
# --install, so there may be no ArgoCD Application to find at all - both
# attempts below fail safely if their target is already gone or never
# existed.
kubectl delete application devops-app -n argocd --timeout=120s 2>/dev/null \
    || info "No ArgoCD Application found, nothing to cascade-delete here - continuing."
# The Namespace is chart-managed now, so the Application delete above should
# already be pruning it - this is a backstop that also blocks until it's
# fully gone, which the next step (waiting for the load balancer) relies on.
kubectl delete namespace devops-app --ignore-not-found=true 2>/dev/null \
    || info "No cluster reachable, nothing to delete here - continuing."
# ArgoCD (if still installed), cert-manager, and Fluent Bit (the argocd/
# cert-manager/amazon-cloudwatch namespaces) are left alone on purpose - none
# of them own AWS resources directly (their IAM roles are deleted separately
# in step [5/8], the CloudWatch log group by `terraform destroy` in step
# [7/8]), so they disappear for free when `eksctl delete cluster` runs in
# step [6/8]. Deleting them here would just make the script wait on
# components terminating for no benefit.

step "[2/8] Waiting for the AWS Load Balancer to fully release..."
# kubectl delete only removes the Service object immediately - the actual
# AWS ELB/NLB and the network interfaces it planted in our subnets are
# cleaned up asynchronously by a controller running INSIDE the cluster.
# Deleting the cluster before that finishes orphans the load balancer with
# nothing left to clean it up, and `terraform destroy` fails later with a
# VPC DependencyViolation. So: wait here until no load balancer remains in
# the VPC.
VPC_ID=$( (cd terraform && terraform output -raw vpc_id 2>/dev/null) || true)
if [ -n "$VPC_ID" ]; then
    WAITED=0
    MAX_WAIT=300
    while true; do
        LB_COUNT=$(aws elb describe-load-balancers --region us-east-1 \
            --query "length(LoadBalancerDescriptions[?VPCId=='$VPC_ID'])" --output text 2>/dev/null || echo 0)
        LB_COUNT_V2=$(aws elbv2 describe-load-balancers --region us-east-1 \
            --query "length(LoadBalancers[?VpcId=='$VPC_ID'])" --output text 2>/dev/null || echo 0)
        if [ "$LB_COUNT" = "0" ] && [ "$LB_COUNT_V2" = "0" ]; then
            success "No load balancer left in the VPC - safe to delete the cluster."
            break
        fi
        if [ "$WAITED" -ge "$MAX_WAIT" ]; then
            echo -e "${YELLOW}    ⚠ Still waiting after 5 minutes - proceeding anyway.${RESET}"
            info "If 'terraform destroy' fails later with a VPC DependencyViolation, list"
            info "network interfaces in the VPC to find and manually delete what's stuck:"
            info "  aws ec2 describe-network-interfaces --region us-east-1 --filters Name=vpc-id,Values=$VPC_ID"
            break
        fi
        info "Still attached, waiting... (${WAITED}s elapsed, checking every 10s)"
        sleep 10
        WAITED=$((WAITED + 10))
    done
else
    info "Could not read the VPC ID from Terraform state - skipping this check."
fi

step "[3/8] Revoking the RDS rule that references the EKS cluster's security group..."
# setup.sh authorized RDS's security group to accept traffic from the EKS
# cluster's security group. AWS won't delete a security group that's still
# referenced elsewhere, so without this the cluster's own cleanup leaves it
# orphaned, and `terraform destroy` later fails trying to delete the VPC.
RDS_SG_ID=$( (cd terraform && terraform output -raw rds_security_group_id 2>/dev/null) || true)
if [ -n "$RDS_SG_ID" ] && eksctl get cluster --name devops-cluster --region us-east-1 >/dev/null 2>&1; then
    EKS_SG_ID=$(aws eks describe-cluster --name devops-cluster --region us-east-1 \
        --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || true)
    if [ -n "$EKS_SG_ID" ] && [ "$EKS_SG_ID" != "None" ]; then
        aws ec2 revoke-security-group-ingress \
            --group-id "$RDS_SG_ID" --protocol tcp --port 5432 \
            --source-group "$EKS_SG_ID" --region us-east-1 >/dev/null 2>&1 \
            && success "Revoked - EKS can now clean up its cluster security group properly." \
            || info "Rule already gone, continuing."
    fi
else
    info "No RDS security group or no live cluster found - nothing to revoke."
fi

step "[4/8] Deleting the Jenkins PVC before the cluster disappears..."
# Same reasoning as the load balancer wait above: `helm uninstall` (and even
# `eksctl delete cluster` on its own) does NOT delete the PVC a StatefulSet
# creates via volumeClaimTemplates - that's deliberate K8s behavior to
# protect data. Left alone, the underlying EBS volume outlives the cluster
# and keeps costing money with nothing left to clean it up. Deleting the PVC
# here, while the EBS CSI driver is still running, lets it actually finish
# deleting the EBS volume before the cluster is gone.
if eksctl get cluster --name devops-cluster --region us-east-1 >/dev/null 2>&1; then
    helm uninstall jenkins -n jenkins --wait --timeout=120s 2>/dev/null \
        || info "No Jenkins Helm release found, continuing."
    kubectl delete pvc --all -n jenkins --timeout=120s 2>/dev/null \
        || info "No Jenkins PVC found, continuing."
    info "Confirming the EBS volume actually finished deleting..."
    WAITED=0
    while true; do
        VOL_COUNT=$(aws ec2 describe-volumes --region us-east-1 \
            --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=*" "Name=status,Values=available,in-use" \
            --query "length(Volumes[?contains(Tags[?Key=='kubernetes.io/created-for/pvc/namespace'].Value | [0], 'jenkins')])" \
            --output text 2>/dev/null || echo 0)
        [ "$VOL_COUNT" = "0" ] && { success "Jenkins EBS volume cleaned up."; break; }
        [ "$WAITED" -ge 120 ] && { echo -e "${YELLOW}    ⚠ Still waiting after 2 minutes - proceeding anyway. Check 'aws ec2 describe-volumes' manually afterward.${RESET}"; break; }
        sleep 10; WAITED=$((WAITED + 10))
    done
else
    info "No live cluster found - nothing to clean up here."
fi

step "[5/8] Deleting IRSA IAM service accounts (backend-sa, worker-sa, ci-build-sa, fluent-bit-sa, external-secrets-sa)..."
# Same lesson as the security-group rule above: these were created by
# `eksctl create iamserviceaccount` as their own CloudFormation stacks,
# separate from the main cluster stack. Deleting them explicitly first
# (rather than assuming `eksctl delete cluster` cleans them up) avoids
# leaving orphaned IAM roles behind, the same way the security group got
# orphaned before.
if eksctl get cluster --name devops-cluster --region us-east-1 >/dev/null 2>&1; then
    eksctl delete iamserviceaccount --verbose 0 \
        --cluster devops-cluster --region us-east-1 \
        --namespace jenkins --name ci-build-sa \
        --wait >/dev/null 2>&1 && success "Deleted IAM role for ci-build-sa." \
        || info "ci-build-sa's IAM role already gone, continuing."
    for sa in backend-sa worker-sa; do
        eksctl delete iamserviceaccount --verbose 0 \
            --cluster devops-cluster --region us-east-1 \
            --namespace devops-app --name "$sa" \
            --wait >/dev/null 2>&1 && success "Deleted IAM role for $sa." \
            || info "$sa's IAM role already gone, continuing."
    done
    # Different namespaces than the two above, so they can't share that loop.
    eksctl delete iamserviceaccount --verbose 0 \
        --cluster devops-cluster --region us-east-1 \
        --namespace amazon-cloudwatch --name fluent-bit-sa \
        --wait >/dev/null 2>&1 && success "Deleted IAM role for fluent-bit-sa." \
        || info "fluent-bit-sa's IAM role already gone, continuing."
    eksctl delete iamserviceaccount --verbose 0 \
        --cluster devops-cluster --region us-east-1 \
        --namespace external-secrets --name external-secrets-sa \
        --wait >/dev/null 2>&1 && success "Deleted IAM role for external-secrets-sa." \
        || info "external-secrets-sa's IAM role already gone, continuing."
else
    info "No live cluster found - nothing to delete here."
fi

step "[6/8] Deleting EKS cluster (10-15 minutes)..."
# eksctl's own progress output is a wall of CloudFormation stack-wait lines -
# logged to a temp file instead of the terminal, and only shown if something
# actually goes wrong, so a normal run just prints one clean result line.
if eksctl get cluster --name devops-cluster --region us-east-1 >/dev/null 2>&1; then
    EKSCTL_LOG=$(mktemp)
    if eksctl delete cluster --verbose 0 --region=us-east-1 --name=devops-cluster > "$EKSCTL_LOG" 2>&1; then
        success "EKS cluster deleted."
    else
        cat "$EKSCTL_LOG"
        fail "eksctl delete cluster failed - see output above."
    fi
    rm -f "$EKSCTL_LOG"
else
    info "Cluster already gone, continuing."
fi

step "[7/8] Destroying Terraform infrastructure (RDS, S3, SNS, IAM, VPC)..."
cd terraform
# Never assume the local .terraform/ cache is already correctly pointed at
# the real S3 backend - init is cheap and idempotent when it's already
# right, and it's what actually fixes things on the rare occasion the cache
# fell out of sync (e.g. someone ran `terraform init -backend=false` here
# for a one-off test and never reconfigured it back).
terraform init -input=false
# None of these values affect what gets destroyed (destroy operates on
# existing state, not on what the variables would have created) - they're
# only set so the command never blocks on a variable prompt, whether or not
# terraform.tfvars happens to exist right now.
export TF_VAR_db_password="unused-during-teardown"
export TF_VAR_bucket_name="unused-during-teardown"
export TF_VAR_my_email="unused-during-teardown"
# Same idea as eksctl above: terraform destroy narrates every resource as it
# goes, which is just noise on a normal run - logged to a temp file, only
# surfaced in full if the destroy fails. -input=false is the important part:
# if a variable were ever missing, this fails immediately with a clear error
# instead of blocking on a prompt hidden inside that log file.
TF_LOG=$(mktemp)
if terraform destroy -auto-approve -input=false > "$TF_LOG" 2>&1; then
    grep -E "^(Destroy complete|No changes)" "$TF_LOG" || true
    success "Terraform infrastructure destroyed."
else
    cat "$TF_LOG"
    fail "terraform destroy failed - see output above."
fi
rm -f "$TF_LOG"
cd ..
# ECR repos (devops-frontend/backend/worker) are Terraform-managed
# (terraform/ecr.tf, force_delete = true) as of Assignment 4, so the destroy
# above already removed them along with every image pushed into them - no
# separate `aws ecr delete-repository` step needed anymore.

step "[8/9] Removing locally-generated files..."
rm -f terraform/terraform.tfvars
success "Removed terraform/terraform.tfvars (setup.sh recreates it, asking again, on the next run)."

step "[9/9] Stopping any leftover local 'kubectl port-forward svc/jenkins' processes..."
# Local hygiene only, not an AWS resource - pkill's own exit code is ignored,
# since "nothing matched" and "not supported on this platform" both look the
# same to this script and neither should fail the teardown.
pkill -f "port-forward svc/jenkins" 2>/dev/null && success "Stopped." || info "None running, nothing to stop."

echo -e "\n${GREEN}${BOLD}=================================================================="
echo "  TEARDOWN COMPLETE - AWS account is clean of EKS and Terraform resources."
echo -e "==================================================================${RESET}"
echo "  Confirm nothing billable was left behind: bash verify-teardown.sh"
echo "  (A GitHub webhook may still be configured on the repo, if one was set"
echo "  up for Jenkins - it's not an AWS resource, so this script leaves it"
echo "  alone. Remove it by hand under Settings > Webhooks if you want it gone.)"
