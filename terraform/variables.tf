variable "aws_region" {
  description = "The AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "db_password" {
  description = "Password for the RDS PostgreSQL database"
  type        = string
  sensitive   = true
}

variable "my_email" {
  description = "Email address for SNS alerts"
  type        = string
}

variable "bucket_name" {
  description = "Globally unique name for the S3 bucket"
  type        = string
}
