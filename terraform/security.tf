# RDS Security Group
#
# No inline `ingress` block here on purpose: the actual rule (allow port 5432
# from the EKS cluster's security group) is added by setup.sh via `aws ec2
# authorize-security-group-ingress` after the cluster exists, since Terraform
# doesn't manage the EKS cluster or know its security group ID. Terraform just
# owns the security group container itself.
resource "aws_security_group" "rds_sg" {
  name        = "rds_sg"
  description = "Database access rule is added by setup.sh once the EKS cluster exists"
  vpc_id      = aws_vpc.main_vpc.id
}
