data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  public_subnets = { for i, cidr in var.public_subnet_cidrs : cidr => data.aws_availability_zones.available.names[i] }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.key
  availability_zone       = each.value
  map_public_ip_on_launch = true

  lifecycle {
    precondition {
      condition     = length(var.public_subnet_cidrs) <= length(data.aws_availability_zones.available.names)
      error_message = "More public subnet CIDRs than available availability zones in this region."
    }
  }

  tags = merge({ Name = "${var.name}-public-subnet-${each.value}" }, var.tags)
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge({ Name = "${var.name}-public-rt" }, var.tags)
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
