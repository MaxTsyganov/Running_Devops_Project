# Public Frontend Server
resource "aws_instance" "frontend" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.frontend_sg.id]
  key_name               = var.key_name

  tags = {
    Name = "DevOps-Frontend-Server"
    Role = "frontend"
  }
}

# Private Backend Server
resource "aws_instance" "backend" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_subnet_1.id
  vpc_security_group_ids = [aws_security_group.backend_sg.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  tags = {
    Name = "DevOps-Backend-Server"
    Role = "backend"
  }
}

# Private Worker Server
resource "aws_instance" "worker" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_subnet_1.id
  vpc_security_group_ids = [aws_security_group.worker_sg.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  tags = {
    Name = "DevOps-Worker-Server"
    Role = "worker"
  }
}