# Owned by Terraform, not auto-created by Fluent Bit, so it's torn down with
# everything else on `terraform destroy` instead of being left orphaned
# outside Terraform's state.
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/devops-app/containers"
  retention_in_days = 7 # keep CloudWatch storage cost bounded for a course project

  tags = {
    Name = "DevOps-App-Log-Group"
  }
}
