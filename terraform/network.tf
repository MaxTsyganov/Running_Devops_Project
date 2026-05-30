# 1. Create the main VPC
resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "DevOps-Project-VPC" }
}

# 2. Create the Public Subnet (For Frontend/Nginx & NAT Gateway)
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = { Name = "DevOps-Public-Subnet" }
}

# 3. Create Private Subnet 1 (For Backend/Worker)
resource "aws_subnet" "private_subnet_1" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"

  tags = { Name = "DevOps-Private-Subnet-1" }
}

# 4. Create Private Subnet 2 (Required for RDS Subnet Group)
resource "aws_subnet" "private_subnet_2" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "${var.aws_region}b"

  tags = { Name = "DevOps-Private-Subnet-2" }
}

# 5. Create the Internet Gateway (The Front Door)
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id
  tags   = { Name = "DevOps-Internet-Gateway" }
}

# 6. Create the Public Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    cidr_block = "0.0.0.0/0"     
    gateway_id = aws_internet_gateway.igw.id 
  }
  tags = { Name = "DevOps-Public-Route-Table" }
}

# 7. Associate the Route Table with the Public Subnet
resource "aws_route_table_association" "public_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# =======================================================
# NEW: NAT GATEWAY AND PRIVATE ROUTING
# =======================================================

# 8. Create an Elastic IP for the NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags   = { Name = "DevOps-NAT-EIP" }
}

# 9. Create the NAT Gateway in the Public Subnet
resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id
  tags          = { Name = "DevOps-NAT-Gateway" }
  depends_on    = [aws_internet_gateway.igw]
}

# 10. Create the Private Route Table (Routes to the NAT)
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
  tags = { Name = "DevOps-Private-Route-Table" }
}

# 11. Associate Private Subnet 1 with the Private Route Table
resource "aws_route_table_association" "private_association_1" {
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.private_rt.id
}