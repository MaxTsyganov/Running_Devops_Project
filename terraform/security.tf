# Frontend Security Group
resource "aws_security_group" "frontend_sg" {
  name        = "frontend_sg"
  description = "Allow web traffic and SSH"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description = "HTTP traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH restricted to local machine IP"
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

# Backend Security Group
resource "aws_security_group" "backend_sg" {
  name        = "backend_sg"
  description = "Allow API traffic and SSH from Frontend only"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description     = "API traffic from Frontend"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id]
  }

  ingress {
    description     = "SSH from Frontend Bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Worker Security Group
resource "aws_security_group" "worker_sg" {
  name        = "worker_sg"
  description = "Allow SSH from Frontend only"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description     = "SSH from Frontend Bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS Security Group
resource "aws_security_group" "rds_sg" {
  name        = "rds_sg"
  description = "Allow database access from Backend and Worker"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description     = "Database access from internal servers"
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