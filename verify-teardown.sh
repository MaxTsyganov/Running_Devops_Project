#!/bin/bash
# Confirms teardown.sh actually left nothing behind - checks every category
# of resource that either costs money while it exists (compute, storage,
# load balancers, NAT gateways), that teardown.sh has been found to miss
# before (see its own commit history), or that could silently block a clean
# setup.sh re-run later even though it costs nothing (e.g. a stuck
# CloudFormation stack). Read-only: never deletes anything, just reports.

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

# Leftover eksctl CloudFormation stacks - each `eksctl create cluster` /
# `eksctl create iamserviceaccount` call creates its own stack. None of these
# cost money by existing, but a stuck one (e.g. DELETE_FAILED) blocks a clean
# `setup.sh` re-run later and won't show up in any resource-specific check
# above if the resources it once owned are already individually gone.
CFN_COUNT=$(aws cloudformation list-stacks --region "$REGION" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
    --query "length(StackSummaries[?starts_with(StackName, 'eksctl-devops-cluster')])" \
    --output text 2>/dev/null || echo 0)
[ "$CFN_COUNT" = "0" ] && ok "No leftover eksctl CloudFormation stacks." || bad "$CFN_COUNT leftover eksctl CloudFormation stack(s) still exist (would block a clean re-run)."

# Terraform-managed IAM policies (a different resource class than the
# eksctl-created roles above - terraform/iam.tf's DevOps-* policies)
POLICY_COUNT=$(aws iam list-policies --scope Local \
    --query "length(Policies[?starts_with(PolicyName, 'DevOps-')])" \
    --output text 2>/dev/null || echo 0)
[ "$POLICY_COUNT" = "0" ] && ok "No leftover DevOps-* IAM policies." || bad "$POLICY_COUNT leftover DevOps-* IAM policy/policies still exist."

# Secrets Manager secret (the RDS password) - deleted outright by
# `terraform destroy` (no recovery window override in secrets.tf), so
# nothing should show here at all, not even a pending-deletion entry.
SECRET_COUNT=$(aws secretsmanager list-secrets --region "$REGION" \
    --query "length(SecretList[?contains(Name, 'devops-app')])" \
    --output text 2>/dev/null || echo 0)
[ "$SECRET_COUNT" = "0" ] && ok "No leftover Secrets Manager secret." || bad "$SECRET_COUNT leftover Secrets Manager secret(s) still exist."

# CloudWatch log group (terraform/logging.tf) - MSYS_NO_PATHCONV=1: the
# /devops-app prefix looks like a Unix path to Windows Git Bash, which
# silently rewrites it into a Windows path before aws-cli ever sees it
# otherwise (the exact bug fixed in setup.sh's Fluent Bit step - see that
# commit). No-op everywhere else.
LOGGROUP_COUNT=$(MSYS_NO_PATHCONV=1 aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "/devops-app" \
    --query "length(logGroups)" --output text 2>/dev/null || echo 0)
[ "$LOGGROUP_COUNT" = "0" ] && ok "No leftover CloudWatch log group." || bad "$LOGGROUP_COUNT leftover CloudWatch log group(s) still exist."

# SNS topic
SNS_COUNT=$(aws sns list-topics --region "$REGION" \
    --query "length(Topics[?contains(TopicArn, 'devops')])" \
    --output text 2>/dev/null || echo 0)
[ "$SNS_COUNT" = "0" ] && ok "No leftover SNS topic." || bad "$SNS_COUNT leftover SNS topic(s) still exist."

# S3 bucket
S3_COUNT=$(aws s3api list-buckets \
    --query "length(Buckets[?contains(Name, 'devops-app')])" \
    --output text 2>/dev/null || echo 0)
[ "$S3_COUNT" = "0" ] && ok "No leftover S3 bucket." || bad "$S3_COUNT leftover S3 bucket(s) still exist."

# Cosign KMS key (terraform/kms.tf) - has a mandatory 7-day AWS deletion
# window (deletion_window_in_days), so a healthy `terraform destroy` leaves
# it in PendingDeletion, not gone outright - that state is correct and
# expected, not a leak. Only flag a key that's still Enabled (destroy
# never scheduled it at all) or PendingDeletion with a description that
# doesn't match this project's key at all is fine to ignore; the real
# failure mode is finding *this* project's key still Enabled.
KMS_STATE=$(aws kms list-aliases --region "$REGION" \
    --query "Aliases[?AliasName=='alias/devops-app-cosign'].TargetKeyId" \
    --output text 2>/dev/null || echo "")
if [ -z "$KMS_STATE" ]; then
    # Alias itself is gone (deletes instantly, no window) - check no Enabled
    # key with this project's description is still sitting around under a
    # different alias somehow.
    KMS_ENABLED=$(aws kms list-keys --region "$REGION" --query "Keys[].KeyId" --output text 2>/dev/null | tr '\t' '\n' | while read -r kid; do
        aws kms describe-key --key-id "$kid" --region "$REGION" \
            --query "KeyMetadata.[KeyState,Description]" --output text 2>/dev/null | grep -q "^ENABLED.*Cosign" && echo "$kid"
    done)
    [ -z "$KMS_ENABLED" ] && ok "Cosign KMS key gone or correctly pending deletion." \
        || bad "Cosign KMS key(s) still Enabled (never scheduled for deletion): $KMS_ENABLED"
else
    bad "Cosign KMS alias 'alias/devops-app-cosign' still exists (points to $KMS_STATE) - destroy may not have run against it."
fi

echo ""
if [ "$FOUND" -eq 0 ]; then
    echo -e "${BOLD}${GREEN}Everything's clean - nothing left that should be costing money.${RESET}"
else
    echo -e "${BOLD}${RED}Something's still around - see ✘ lines above before assuming this is fully torn down.${RESET}"
    exit 1
fi
