#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/output.sh"

echo -e "${BOLD}=================================================================="
echo "  DevOps App - Full Teardown"
echo "  This deletes Kubernetes workloads, Jenkins, the EKS cluster, and every"
echo "  Terraform-managed AWS resource (RDS, S3, SNS, ECR, IAM, networking)."
echo -e "==================================================================${RESET}"

step "[1/11] Deleting the app namespace..."
# Assignment 4 replaced ArgoCD (Application + resources-finalizer cascade
# delete) with Jenkins CD via helm upgrade --install, so there may be no
# ArgoCD Application to find - both attempts below fail safely either way.
kubectl delete application devops-app -n argocd --timeout=120s 2>/dev/null \
    || info "No ArgoCD Application found, nothing to cascade-delete here - continuing."
# The Namespace is chart-managed now, so the Application delete above should
# already be pruning it - this is a backstop that also blocks until it's
# fully gone, which the next step (waiting for the load balancer) relies on.
kubectl delete namespace devops-app --ignore-not-found=true 2>/dev/null \
    || info "No cluster reachable, nothing to delete here - continuing."
# ArgoCD, cert-manager, and Fluent Bit's namespaces are left alone here -
# none own AWS resources directly (IAM roles deleted in [6/11], log group by
# `terraform destroy` in [9/11]), so they disappear for free when `eksctl
# delete cluster` runs in [7/11].

step "[2/11] Waiting for the AWS Load Balancer to fully release..."
# kubectl delete only removes the Service object - the actual AWS ELB/NLB
# and its ENIs are cleaned up asynchronously by an in-cluster controller.
# Deleting the cluster first orphans the load balancer and `terraform
# destroy` later fails with a VPC DependencyViolation, so wait here instead.
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

step "[3/11] Revoking the RDS rule that references the EKS cluster's security group..."
# setup.sh authorized RDS's SG to accept traffic from the EKS cluster's SG.
# AWS won't delete a SG still referenced elsewhere, so without this the
# cluster's cleanup leaves it orphaned and `terraform destroy` fails on the VPC.
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

step "[4/11] Deleting the Jenkins PVC before the cluster disappears..."
# Same reasoning as the load balancer wait: `helm uninstall` doesn't delete
# a StatefulSet's PVC (deliberate K8s data-protection behavior), which would
# otherwise leave its EBS volume costing money with nothing left to delete
# it. Deleting it here, while the EBS CSI driver still runs, finishes the job.
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

step "[5/11] Deleting the observability PVC before the cluster disappears..."
# Same reasoning as the Jenkins PVC step above - Prometheus's PVC
# (observability/values.yaml: 5Gi, ebs-gp3) would orphan its EBS volume the same way.
if eksctl get cluster --name devops-cluster --region us-east-1 >/dev/null 2>&1; then
    helm uninstall observability -n observability --wait --timeout=120s 2>/dev/null \
        || info "No observability Helm release found, continuing."
    kubectl delete pvc --all -n observability --timeout=120s 2>/dev/null \
        || info "No observability PVC found, continuing."
    info "Confirming the EBS volume actually finished deleting..."
    WAITED=0
    while true; do
        VOL_COUNT=$(aws ec2 describe-volumes --region us-east-1 \
            --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=*" "Name=status,Values=available,in-use" \
            --query "length(Volumes[?contains(Tags[?Key=='kubernetes.io/created-for/pvc/namespace'].Value | [0], 'observability')])" \
            --output text 2>/dev/null || echo 0)
        [ "$VOL_COUNT" = "0" ] && { success "Observability EBS volume cleaned up."; break; }
        [ "$WAITED" -ge 120 ] && { echo -e "${YELLOW}    ⚠ Still waiting after 2 minutes - proceeding anyway. Check 'aws ec2 describe-volumes' manually afterward.${RESET}"; break; }
        sleep 10; WAITED=$((WAITED + 10))
    done
else
    info "No live cluster found - nothing to clean up here."
fi

step "[6/11] Deleting IRSA IAM service accounts (backend-sa, worker-sa, ci-build-sa, fluent-bit-sa, external-secrets-sa, cluster-autoscaler-sa)..."
# Same lesson as the security-group rule above: `eksctl create
# iamserviceaccount` creates its own CloudFormation stack, separate from the
# cluster's - deleted explicitly here so it doesn't outlive the cluster the same way.
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
    # Uninstalled first, not just its IRSA role pulled out from under it -
    # otherwise it keeps running with a now-invalid IAM role reference.
    helm uninstall cluster-autoscaler -n kube-system >/dev/null 2>&1 \
        || info "No Cluster Autoscaler Helm release found, continuing."
    eksctl delete iamserviceaccount --verbose 0 \
        --cluster devops-cluster --region us-east-1 \
        --namespace kube-system --name cluster-autoscaler-sa \
        --wait >/dev/null 2>&1 && success "Deleted IAM role for cluster-autoscaler-sa." \
        || info "cluster-autoscaler-sa's IAM role already gone, continuing."
else
    info "No live cluster found - nothing to delete here."
fi

step "[7/11] Deleting EKS cluster (10-15 minutes)..."
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

step "[8/11] Cleaning up orphaned EKS networking objects (VPC-CNI ENIs, cluster SG)..."
# eksctl's cluster deletion doesn't clean up two things that don't self-
# resolve: VPC-CNI secondary ENIs ("aws-K8S-i-*", left behind because the
# DaemonSet that owns them is already gone when the node terminates) and the
# EKS-auto-created cluster security group (can't delete while an orphaned
# ENI is still a member). Both silently block terraform destroy's VPC
# deletion with a DependencyViolation, so they're deleted here directly.
if [ -n "$VPC_ID" ]; then
    ORPHAN_ENIS=$(aws ec2 describe-network-interfaces --region us-east-1 \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
        --query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-i-')].NetworkInterfaceId" \
        --output text 2>/dev/null)
    if [ -n "$ORPHAN_ENIS" ]; then
        for eni in $ORPHAN_ENIS; do
            aws ec2 delete-network-interface --region us-east-1 --network-interface-id "$eni" 2>/dev/null \
                && success "Deleted orphaned VPC-CNI ENI $eni." \
                || info "Could not delete $eni (may already be gone) - continuing."
        done
    else
        info "No orphaned VPC-CNI ENIs found."
    fi
    # Retried, not one-shot: AWS's eventual consistency for "is any ENI
    # still a member" can lag a few seconds behind the ENI deletion above.
    ORPHAN_SGS=$(aws ec2 describe-security-groups --region us-east-1 \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=eks-cluster-sg-devops-cluster-*" \
        --query "SecurityGroups[].GroupId" --output text 2>/dev/null)
    if [ -n "$ORPHAN_SGS" ]; then
        for sg in $ORPHAN_SGS; do
            SG_DELETED=false
            for _ in 1 2 3 4 5; do
                aws ec2 delete-security-group --region us-east-1 --group-id "$sg" 2>/dev/null \
                    && { SG_DELETED=true; break; }
                sleep 5
            done
            [ "$SG_DELETED" = true ] \
                && success "Deleted orphaned EKS cluster security group $sg." \
                || info "Could not delete $sg after retrying (still has a dependency) - terraform destroy will retry."
        done
    else
        info "No orphaned EKS cluster security group found."
    fi
else
    info "Could not read the VPC ID - skipping this check."
fi

step "[9/11] Destroying Terraform infrastructure (RDS, S3, SNS, IAM, VPC)..."
cd terraform
# Never assume the local .terraform/ cache is correctly pointed at the S3
# backend - init is cheap when already right, and fixes it on the rare
# occasion it fell out of sync (e.g. a stray `-backend=false` test run).
terraform init -input=false
# These values don't affect what gets destroyed (destroy operates on
# existing state) - only set so the command never blocks on a variable prompt.
export TF_VAR_db_password="unused-during-teardown"
export TF_VAR_bucket_name="unused-during-teardown"
export TF_VAR_my_email="unused-during-teardown"
# Same idea as eksctl above: destroy's noisy resource-by-resource narration
# goes to a temp file, only surfaced if it fails. -input=false matters most:
# a missing variable fails immediately instead of blocking on a hidden prompt.
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
# ECR repos are Terraform-managed (terraform/ecr.tf, force_delete = true),
# so the destroy above already removed them - no separate delete step needed.

step "[10/11] Removing locally-generated files..."
rm -f terraform/terraform.tfvars
success "Removed terraform/terraform.tfvars (setup.sh recreates it, asking again, on the next run)."

step "[11/11] Stopping any leftover local 'kubectl port-forward svc/jenkins' processes..."
# Local hygiene only, not an AWS resource - pkill's exit code is ignored,
# since "nothing matched" and "unsupported platform" both look the same here.
pkill -f "port-forward svc/jenkins" 2>/dev/null && success "Stopped." || info "None running, nothing to stop."

echo -e "\n${GREEN}${BOLD}=================================================================="
echo "  TEARDOWN COMPLETE - AWS account is clean of EKS and Terraform resources."
echo -e "==================================================================${RESET}"
echo "  Confirm nothing billable was left behind: bash verify-teardown.sh"
echo "  (A GitHub webhook may still be configured on the repo, if one was set"
echo "  up for Jenkins - it's not an AWS resource, so this script leaves it"
echo "  alone. Remove it by hand under Settings > Webhooks if you want it gone.)"
