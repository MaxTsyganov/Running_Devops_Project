#!/bin/bash
set -e

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RESET='\033[0m'
step()    { echo -e "\n${BOLD}${YELLOW}==> $1${RESET}"; }
info()    { echo "    $1"; }
success() { echo -e "${GREEN}✔ $1${RESET}"; }

echo -e "${BOLD}=================================================================="
echo "  DevOps App - Full Teardown"
echo "  This deletes Kubernetes workloads, the EKS cluster, and every"
echo "  Terraform-managed AWS resource (RDS, S3, SNS, IAM, networking)."
echo -e "==================================================================${RESET}"

step "[1/7] Deleting the app via ArgoCD, then removing ArgoCD itself..."
# The Application was created with a resources-finalizer, so deleting it makes
# ArgoCD prune every resource it manages (Deployments, Services, etc.) before
# the Application object itself is removed - this is what actually tears down
# the app, not a `helm uninstall` (ArgoCD owns the release now, not us directly).
kubectl delete application devops-app -n argocd --timeout=120s 2>/dev/null \
    || info "No ArgoCD Application found, nothing to cascade-delete here - continuing."
# The Namespace is chart-managed now, so the Application delete above should
# already be pruning it - this is a backstop that also blocks until it's fully
# gone, which the next step (waiting for the load balancer to release) relies on.
kubectl delete namespace devops-app --ignore-not-found=true 2>/dev/null \
    || info "No cluster reachable, nothing to delete here - continuing."
# ArgoCD itself (the argocd namespace) is left alone here on purpose - it has
# no AWS resources of its own (no LoadBalancer, no IAM role), so it disappears
# for free when `eksctl delete cluster` runs in step [5/7]. Deleting it here
# would just make the script wait on ~7 components terminating for no benefit.

step "[2/7] Waiting for the AWS Load Balancer to fully release..."
# kubectl delete only removes the Service object immediately - the actual AWS
# ELB/NLB and the network interfaces it planted in our subnets are cleaned up
# asynchronously by a controller running INSIDE the cluster. If we delete the
# cluster before that finishes, the load balancer gets orphaned with nothing
# left to finish deleting it, and `terraform destroy` fails later with a VPC
# DependencyViolation. So: wait here until no load balancer remains in our VPC.
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

step "[3/7] Revoking the RDS rule that references the EKS cluster's security group..."
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

step "[4/7] Deleting IRSA IAM service accounts (backend-sa, worker-sa)..."
# Same lesson as the security-group rule above: these were created by `eksctl
# create iamserviceaccount` as their own CloudFormation stacks, separate from
# the main cluster stack. Deleting them explicitly first (rather than assuming
# `eksctl delete cluster` cleans them up) avoids leaving orphaned IAM roles
# behind, the same way the orphaned cluster security group happened before.
if eksctl get cluster --name devops-cluster --region us-east-1 >/dev/null 2>&1; then
    for sa in backend-sa worker-sa; do
        eksctl delete iamserviceaccount \
            --cluster devops-cluster --region us-east-1 \
            --namespace devops-app --name "$sa" \
            --wait 2>/dev/null && success "Deleted IAM role for $sa." \
            || info "$sa's IAM role already gone, continuing."
    done
else
    info "No live cluster found - nothing to delete here."
fi

step "[5/7] Deleting EKS cluster (10-15 minutes)..."
eksctl delete cluster --region=us-east-1 --name=devops-cluster 2>/dev/null || info "Cluster already gone, continuing."

step "[6/7] Destroying Terraform infrastructure (RDS, S3, SNS, IAM, VPC)..."
cd terraform
# db_password's real value is irrelevant for `destroy` (it's never re-sent to AWS
# on delete), so a throwaway value avoids prompting for a secret we're about to
# delete anyway - the real password is never stored on disk between runs.
export TF_VAR_db_password="unused-during-teardown"
terraform destroy -auto-approve
cd ..

step "[7/7] Removing locally-generated files..."
rm -f terraform/terraform.tfvars
success "Removed terraform/terraform.tfvars (setup.sh recreates it, asking again, on the next run)."

echo -e "\n${GREEN}${BOLD}=================================================================="
echo "  TEARDOWN COMPLETE - AWS account is clean of EKS and Terraform resources."
echo -e "==================================================================${RESET}"
