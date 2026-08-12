#!/bin/bash
# Confirms teardown.sh actually left nothing behind that could keep costing
# money - checks every category of resource that either costs money while
# it exists (compute, storage, load balancers, NAT gateways) or that
# teardown.sh has ever been found to miss (see its own commit history).
# Read-only: never deletes anything itself, just reports.

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}✔ $1${RESET}"; }
bad()  { echo -e "${RED}✘ $1${RESET}"; FOUND=1; }
FOUND=0
REGION=us-east-1

echo -e "${BOLD}Checking for anything left behind after teardown...${RESET}\n"

# EKS cluster
if eksctl get cluster --name devops-cluster --region "$REGION" >/dev/null 2>&1; then
    bad "EKS cluster 'devops-cluster' still exists."
else
    ok "EKS cluster gone."
fi

# EC2 instances (the cluster's worker nodes specifically, tagged by eksctl)
EC2_COUNT=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=devops-cluster" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query "length(Reservations[].Instances[])" --output text 2>/dev/null || echo 0)
[ "$EC2_COUNT" = "0" ] && ok "No leftover EC2 instances." || bad "$EC2_COUNT EC2 instance(s) still exist for this cluster."

# RDS
RDS_COUNT=$(aws rds describe-db-instances --region "$REGION" \
    --query "length(DBInstances[?contains(DBInstanceIdentifier, 'appdb') || contains(DBInstanceIdentifier, 'devops')])" \
    --output text 2>/dev/null || echo 0)
[ "$RDS_COUNT" = "0" ] && ok "No leftover RDS instances." || bad "$RDS_COUNT RDS instance(s) still exist."

# EBS volumes (the Jenkins PVC is the known risk, but check broadly for any
# volume left in "available" state - i.e. detached, definitely orphaned)
EBS_COUNT=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=status,Values=available" \
    --query "length(Volumes[?Tags[?Key=='kubernetes.io/cluster/devops-cluster']])" \
    --output text 2>/dev/null || echo 0)
[ "$EBS_COUNT" = "0" ] && ok "No orphaned EBS volumes." || bad "$EBS_COUNT orphaned EBS volume(s) still exist (e.g. Jenkins PVC)."

# Load balancers
ELB_COUNT=$(aws elb describe-load-balancers --region "$REGION" \
    --query "length(LoadBalancerDescriptions[?contains(LoadBalancerName, 'devops') || contains(LoadBalancerName, 'k8s')])" \
    --output text 2>/dev/null || echo 0)
ELBV2_COUNT=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "length(LoadBalancers[?contains(LoadBalancerName, 'devops') || contains(LoadBalancerName, 'k8s')])" \
    --output text 2>/dev/null || echo 0)
[ "$ELB_COUNT" = "0" ] && [ "$ELBV2_COUNT" = "0" ] \
    && ok "No leftover load balancers." || bad "Load balancer(s) still exist ($ELB_COUNT classic, $ELBV2_COUNT v2)."

# NAT gateways (a real per-hour cost if a VPC teardown left one dangling)
NAT_COUNT=$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=state,Values=available,pending" \
    --query "length(NatGateways)" --output text 2>/dev/null || echo 0)
[ "$NAT_COUNT" = "0" ] && ok "No leftover NAT gateways." || bad "$NAT_COUNT NAT gateway(s) still running."

# Unassociated Elastic IPs (billed hourly once detached from anything)
EIP_COUNT=$(aws ec2 describe-addresses --region "$REGION" \
    --query "length(Addresses[?AssociationId==null])" --output text 2>/dev/null || echo 0)
[ "$EIP_COUNT" = "0" ] && ok "No unassociated Elastic IPs." || bad "$EIP_COUNT unassociated Elastic IP(s) still allocated."

# ECR repositories
for repo in devops-frontend devops-backend devops-worker; do
    if aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1; then
        bad "ECR repository '$repo' still exists."
    else
        ok "ECR repository '$repo' gone."
    fi
done

# VPC (confirms terraform destroy actually finished, not just started)
VPC_COUNT=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=*devops*" \
    --query "length(Vpcs)" --output text 2>/dev/null || echo 0)
[ "$VPC_COUNT" = "0" ] && ok "No leftover project VPC." || bad "$VPC_COUNT project VPC(s) still exist."

# Orphaned IRSA IAM roles (eksctl creates these as their own CloudFormation
# stacks - if a stack delete silently failed, the role can outlive the
# cluster with nothing left pointing at it)
IAM_COUNT=$(aws iam list-roles \
    --query "length(Roles[?contains(RoleName, 'eksctl-devops-cluster')])" \
    --output text 2>/dev/null || echo 0)
[ "$IAM_COUNT" = "0" ] && ok "No orphaned eksctl-created IAM roles." || bad "$IAM_COUNT orphaned eksctl-created IAM role(s) still exist."

echo ""
if [ "$FOUND" -eq 0 ]; then
    echo -e "${BOLD}${GREEN}Everything's clean - nothing left that should be costing money.${RESET}"
else
    echo -e "${BOLD}${RED}Something's still around - see ✘ lines above before assuming this is fully torn down.${RESET}"
    exit 1
fi
