# RDS Security Group
#
# No inline `ingress` block: the real rule (port 5432 from the EKS cluster's
# SG) is added by setup.sh via `aws ec2 authorize-security-group-ingress`
# after the cluster exists - Terraform can't know that SG ID at apply time
# since the VPC must exist before eksctl creates the cluster inside it.
#
# `ignore_changes` stops Terraform from treating this resource as
# authoritative for its rule set and silently stripping setup.sh's rule on
# every later `terraform apply`.
resource "aws_security_group" "rds_sg" {
  name        = "rds_sg"
  description = "Database access rule is added by setup.sh once the EKS cluster exists"
  vpc_id      = aws_vpc.main_vpc.id

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}
