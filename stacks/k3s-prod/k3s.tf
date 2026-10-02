# ---------------------------------------------------------------
# Shared join token (replaces the auto-generated one)
# ---------------------------------------------------------------
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

# ---------------------------------------------------------------
# AMI — latest Ubuntu 24.04 LTS
# ---------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# ---------------------------------------------------------------
# Server nodes — one per AZ, round-robin if count > len(azs)
# ---------------------------------------------------------------
locals {
  # Fixed address for server 0, which bootstraps the cluster; the others join it here.
  server0_ip = cidrhost(local.private_cidrs[var.azs[0]], 20)
}

resource "aws_instance" "k3s_server" {
  count = var.server_count

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private[var.azs[count.index % length(var.azs)]].id
  private_ip                  = count.index == 0 ? local.server0_ip : null
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.k3s.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/scripts/userdata-server.sh.tftpl", {
    k3s_version  = var.k3s_version
    k3s_token    = random_password.k3s_token.result
    cluster_cidr = var.cluster_cidr
    service_cidr = var.service_cidr
    server0_ip   = local.server0_ip
    is_first     = count.index == 0
    node_name    = "k3s-server-${count.index}"
  })

  tags = { Name = "${var.name}-server-${count.index}", Role = "k3s-server" }
}
