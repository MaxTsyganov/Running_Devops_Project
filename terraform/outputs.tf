# Read by setup.sh to configure the Kubernetes ConfigMap/Secret and eksctl.

output "rds_endpoint" {
  description = "The RDS connection endpoint"
  value       = aws_db_instance.postgres.endpoint
}

output "s3_bucket_name" {
  description = "The dynamically generated S3 bucket name"
  value       = aws_s3_bucket.app_bucket.id
}

output "sns_topic_arn" {
  description = "The ARN for the SNS Topic"
  value       = aws_sns_topic.alerts.arn
}

output "cloudwatch_log_group_name" {
  description = "The CloudWatch Log Group Fluent Bit ships container logs to"
  value       = aws_cloudwatch_log_group.app_logs.name
}

output "db_password_secret_name" {
  description = "Secrets Manager secret name holding the DB password - passed to the ExternalSecret as a reference, never the value itself"
  value       = aws_secretsmanager_secret.db_password.name
}

# VPC info needed to put the EKS cluster in the same network as RDS.

output "vpc_id" {
  description = "The VPC that RDS lives in - EKS must be created inside this same VPC"
  value       = aws_vpc.main_vpc.id
}

output "public_subnet_ids" {
  description = "Both public subnets (comma-separated), across 2 AZs, for eksctl --vpc-public-subnets"
  value       = "${aws_subnet.public_subnet.id},${aws_subnet.public_subnet_2.id}"
}

output "private_subnet_ids" {
  description = "Both private subnets (comma-separated), across 2 AZs, for eksctl --vpc-private-subnets"
  value       = "${aws_subnet.private_subnet_1.id},${aws_subnet.private_subnet_2.id}"
}

output "rds_security_group_id" {
  description = "The RDS security group - EKS's node security group must be added to its ingress rules"
  value       = aws_security_group.rds_sg.id
}
