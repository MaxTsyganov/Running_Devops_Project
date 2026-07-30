# RDS Security Group
#
# No inline `ingress` block here on purpose: the actual rule (allow port 5432
# from the EKS cluster's security group) is added by setup.sh via `aws ec2
# authorize-security-group-ingress` after the cluster exists, since Terraform
# doesn't manage the EKS cluster or know its security group ID at apply time -
# the VPC has to exist before eksctl can create the cluster inside it, so
# Terraform can never "discover" the cluster's security group on a first run.
#
# `ignore_changes` tells Terraform to never plan a revert of this security
# group's rules, no matter what it finds live in AWS. Without it, Terraform
# would treat this resource as authoritative for its *entire* rule set (even
# an empty one) and silently strip the rule setup.sh just added on every
# subsequent `terraform apply` - which happens on every single deploy now.
resource "aws_security_group" "rds_sg" {
  name        = "rds_sg"
  description = "Database access rule is added by setup.sh once the EKS cluster exists"
  vpc_id      = aws_vpc.main_vpc.id

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}
