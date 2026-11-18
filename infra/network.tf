# Networking built for this service rather than borrowed: one VPC, two public
# subnets in two AZs, an internet gateway. No NAT gateway, no VPC endpoints, no
# load balancer (docs/vision.md section 3).

data "aws_availability_zones" "available" {
  state = "available"

  # Regular AZs only; never opt-in Local or Wavelength Zones.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.project }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = var.project }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)

  # The public IP is assigned by the ECS service (assign_public_ip in ecs.tf),
  # not by the subnet, so the dependency is explicit where it matters.
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-public-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "service" {
  name        = "${var.project}-service"
  description = "Fixed-response service: HTTP 8080 from one operator address only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-service" }
}

# The only way in. Unauthenticated plain HTTP from a single /32, accepted
# explicitly at Infrastructure Design (see aidlc-docs/audit.md). Never 0.0.0.0/0:
# the operator_cidr variable validation rejects anything wider than /32.
resource "aws_vpc_security_group_ingress_rule" "http_operator" {
  security_group_id = aws_security_group.service.id
  description       = "HTTP from the operator address"
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  cidr_ipv4         = var.operator_cidr
}

# The task only needs HTTPS out: ECR API, S3 for image layers, CloudWatch Logs.
# DNS goes to the VPC resolver, which security groups do not filter.
resource "aws_vpc_security_group_egress_rule" "https_out" {
  security_group_id = aws_security_group.service.id
  description       = "HTTPS to ECR, S3 and CloudWatch Logs via the internet gateway"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
