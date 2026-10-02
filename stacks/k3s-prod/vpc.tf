# ---------------------------------------------------------------------------
# VPC for the K3s cluster
#
#   public  subnets  10.30.0.0/24, 10.30.1.0/24, 10.30.2.0/24   (NLB, NAT gateway)
#   private subnets  10.30.10.0/24, 10.30.11.0/24, 10.30.12.0/24 (cluster nodes)
#
# One NAT gateway (in the first public subnet) serves all private subnets.
# ---------------------------------------------------------------------------
locals {
  public_cidrs  = { for i, az in var.azs : az => cidrsubnet(var.vpc_cidr, 8, i) }
  private_cidrs = { for i, az in var.azs : az => cidrsubnet(var.vpc_cidr, 8, 10 + i) }
  az_suffix     = { for az in var.azs : az => substr(az, -1, 1) }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

# --- Subnets ---------------------------------------------------------------
resource "aws_subnet" "public" {
  for_each = local.public_cidrs

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-public-${local.az_suffix[each.key]}", Tier = "public" }
}

resource "aws_subnet" "private" {
  for_each = local.private_cidrs

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = { Name = "${var.name}-private-${local.az_suffix[each.key]}", Tier = "private" }
}

# --- Public routing: internet gateway ----------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# --- One NAT gateway for all private subnets -----------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[var.azs[0]].id
  tags          = { Name = var.name }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# --- Security group ----------------------------------------------------------
resource "aws_security_group" "k3s" {
  name   = "${var.name}-k3s"
  vpc_id = aws_vpc.this.id

  # kube API: the VPC (incl. NLB health checks) and, since the NLB preserves
  # client IPs, the external allowed_cidrs coming in through it
  ingress {
    description = "k3s supervisor + kube API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = distinct(concat([var.vpc_cidr], var.allowed_cidrs))
  }

  ingress {
    description = "etcd peer"
    from_port   = 2380
    to_port     = 2380
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "node-to-node"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-k3s" }
}
