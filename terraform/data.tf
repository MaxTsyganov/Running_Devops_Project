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

resource "aws_sns_topic" "alerts" {
  name = "devops-project-alerts"
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
