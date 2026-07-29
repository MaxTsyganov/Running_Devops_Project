# Automatically fetch the latest Ubuntu 24.04 AMI for the current region
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS Account

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 1. Database Subnet Group (Required by RDS to know where it can live)
resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "devops-db-subnet-group"
  subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]

  tags = {
    Name = "DevOps-DB-Subnet-Group"
  }
}

# 2. RDS PostgreSQL Database
resource "aws_db_instance" "postgres" {
  identifier        = "appdb-instance"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = "appdb"
  username = "postgres"
  password = var.db_password # Pulled securely from variables

  db_subnet_group_name   = aws_db_subnet_group.db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  skip_final_snapshot = true  # Allows us to easily delete the DB later
  publicly_accessible = false # Strict security: No internet access

  tags = {
    Name = "DevOps-RDS-Postgres"
  }
}

# Generate a random 6-character string to guarantee S3 uniqueness
resource "random_string" "bucket_suffix" {
  length  = 6
  special = false
  upper   = false
}

# 3. S3 Bucket
resource "aws_s3_bucket" "app_bucket" {
  bucket        = "${var.bucket_name}-${random_string.bucket_suffix.result}"
  force_destroy = true

  tags = {
    Name = "DevOps-App-Bucket"
  }
}

# 4. SNS Topic
resource "aws_sns_topic" "alerts" {
  name = "devops-project-alerts"
}

# 5. SNS Email Subscription
resource "aws_sns_topic_subscription" "email_sub" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.my_email # Pulled from variables
}

# 6. Fetch your local machine's public IP dynamically for SSH access
data "http" "my_local_ip" {
  url = "http://ipv4.icanhazip.com"
}

# Automatically fetch available availability zones for the current region
data "aws_availability_zones" "available" {
  state = "available"
}