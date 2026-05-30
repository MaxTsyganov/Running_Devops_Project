# 1. Frontend Security Group
resource "aws_security_group" "frontend_sg" {
  name        = "frontend_sg"
  description = "Allow HTTP/HTTPS from internet and SSH for Ansible"
  vpc_id      = aws_vpc.main_vpc.id

  # HTTP Rule - Allowed from anywhere
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS Rule - Allowed from anywhere (NEW)
  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

# SSH Rule - Dynamically locked to your exact local IP
  ingress {
    description = "SSH for Ansible (Restricted to local machine IP)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_local_ip.response_body)}/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. Backend Security Group
resource "aws_security_group" "backend_sg" {
  name        = "backend_sg"
  description = "Allow inbound API traffic and SSH ONLY from Frontend"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description     = "Flask API from Frontend SG only"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id]
  }

  ingress {
    description     = "SSH strictly from Frontend SG (Bastion Host)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id] # <--- LOCKED DOWN
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Worker Security Group
resource "aws_security_group" "worker_sg" {
  name        = "worker_sg"
  description = "Allow SSH ONLY from Frontend. No inbound app ports needed."
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description     = "SSH strictly from Frontend SG (Bastion Host)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id] # <--- LOCKED DOWN
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 4. RDS PostgreSQL Security Group
resource "aws_security_group" "rds_sg" {
  name        = "rds_sg"
  description = "Allow PostgreSQL access strictly from Backend and Worker"
  vpc_id      = aws_vpc.main_vpc.id

  # Database traffic allowed from Backend and Worker SGs
  ingress {
    description     = "PostgreSQL from Backend and Worker SGs"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [
      aws_security_group.backend_sg.id, 
      aws_security_group.worker_sg.id
    ]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}