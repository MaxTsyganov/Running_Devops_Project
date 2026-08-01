# RDS requires a subnet group spanning at least 2 Availability Zones.
resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "devops-db-subnet-group"
  subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]

  tags = {
    Name = "DevOps-DB-Subnet-Group"
  }
}

resource "aws_db_instance" "postgres" {
  identifier        = "appdb-instance"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = "appdb"
  username = "postgres"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  skip_final_snapshot = true  # no production data to preserve on delete
  publicly_accessible = false # only reachable from inside the VPC
  storage_encrypted   = true  # AWS-managed key, no extra cost

  tags = {
    Name = "DevOps-RDS-Postgres"
  }
}

# S3 bucket names are globally unique across all AWS accounts, so a random
# suffix is appended to the name you choose to avoid collisions.
resource "random_string" "bucket_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_s3_bucket" "app_bucket" {
  bucket        = "${var.bucket_name}-${random_string.bucket_suffix.result}"
  force_destroy = true

  tags = {
    Name = "DevOps-App-Bucket"
  }
}

# Nothing in this project ever needs public bucket access - the backend
# talks to S3 through IRSA, not a public URL - so blocking it entirely has
# no functional downside.
resource "aws_s3_bucket_public_access_block" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 (AES256, AWS-managed key) - free. A customer-managed KMS key would
# satisfy stricter scanners too, but costs ~$1/month for a key this project
# doesn't otherwise need, for marginal benefit on data that isn't sensitive.
# trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "app_bucket" {
  bucket = aws_s3_bucket.app_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Same trade-off as the S3 bucket above: AWS-managed key is free, a
# customer-managed one costs ~$1/month for marginal benefit here.
# trivy:ignore:AWS-0136
resource "aws_sns_topic" "alerts" {
  name              = "devops-project-alerts"
  kms_master_key_id = "alias/aws/sns" # AWS-managed key, no extra cost
}

resource "aws_sns_topic_subscription" "email_sub" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.my_email
}

# Used by network.tf to spread subnets across 2 Availability Zones (EKS requirement).
data "aws_availability_zones" "available" {
  state = "available"
}
