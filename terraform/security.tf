# RDS Security Group
#
# No inline `ingress` block on purpose: the real rule (allow port 5432 from
# the EKS cluster's security group) is added by setup.sh via `aws ec2
# authorize-security-group-ingress` after the cluster exists. Terraform
# doesn't manage the EKS cluster and can't know its security group ID at
# apply time - the VPC has to exist before eksctl can create the cluster
# inside it, so Terraform can never discover that security group on a first
# run.
#
# `ignore_changes` stops Terraform from ever reverting this group's rules to
# match what's declared here. Without it, Terraform treats this resource as
# authoritative for its *entire* rule set (even an empty one) and silently
# strips the rule setup.sh just added on every later `terraform apply` -
# which happens on every deploy.
resource "aws_security_group" "rds_sg" {
  name        = "rds_sg"
  description = "Database access rule is added by setup.sh once the EKS cluster exists"
  vpc_id      = aws_vpc.main_vpc.id

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}
