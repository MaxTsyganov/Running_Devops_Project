# Owned by Terraform (not auto-created by Fluent Bit) so it gets torn down
# automatically with everything else on `terraform destroy` - a log group
# Fluent Bit created itself would be a separate AWS resource outside
# Terraform's state, exactly the kind of thing that's easy to leave orphaned.
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/devops-app/containers"
  retention_in_days = 7 # keep CloudWatch storage cost bounded for a course project

  tags = {
    Name = "DevOps-App-Log-Group"
  }
}
