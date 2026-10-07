# ---------------------------------------------------------------------------
# 1. Official Talos AMI for this region/arch
# ---------------------------------------------------------------------------
data "aws_region" "current" {}

data "http" "cloud_images" {
  url = "https://github.com/siderolabs/talos/releases/download/${var.talos_semver}/cloud-images.json"
}

locals {
  ami_id = [
    for img in jsondecode(data.http.cloud_images.response_body) :
    img.id
    if img.region == data.aws_region.current.region && img.arch == var.arch
  ][0]

  # t3/t4g default to "unlimited" credits, which bills for sustained CPU
  # above baseline even on the free tier. "standard" throttles instead.
  burstable = startswith(var.instance_type, "t")
}

# ---------------------------------------------------------------------------
# 2. The EC2 instance - boots the Talos AMI into maintenance mode
# ---------------------------------------------------------------------------
resource "aws_instance" "talos" {
  ami           = local.ami_id
  instance_type = var.instance_type

  subnet_id                   = var.subnet_id
  associate_public_ip_address = true # ephemeral public IP, no Elastic IP
  vpc_security_group_ids      = [var.security_group_id]

  dynamic "credit_specification" {
    for_each = local.burstable ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.disk_size
    delete_on_termination = true
  }

  tags = merge(var.tags, { Name = var.cluster_name })
}

# ---------------------------------------------------------------------------
# 3. Talos: secrets -> config -> apply -> bootstrap -> kubeconfig
# ---------------------------------------------------------------------------
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "this" {
  cluster_name       = var.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = "https://${aws_instance.talos.public_ip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat([
    yamlencode({
      # The only node: control plane that also runs workloads
      cluster = {
        allowSchedulingOnControlPlanes = true
      }
      # Pin the installer to the AMI's Talos release and the Nitro root disk
      # (the provider default is its own bundled version on /dev/sda)
      machine = {
        install = {
          image = "ghcr.io/siderolabs/installer:${var.talos_semver}"
          disk  = "/dev/nvme0n1"
        }
      }
    }),
  ], var.config_patches)
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [aws_instance.talos.public_ip]
  nodes                = [aws_instance.talos.private_ip]
}

# endpoint = where we connect, node = who the request is for. The node must be
# the private IP: apid forwards to it, and the node can't reach its own public
# IP through the security group.
resource "talos_machine_configuration_apply" "this" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this.machine_configuration
  endpoint                    = aws_instance.talos.public_ip
  node                        = aws_instance.talos.private_ip

  # graceful = false: a single-node etcd can't remove its last member, so a
  # graceful reset fails on destroy.
  on_destroy = {
    graceful = false
    reset    = true
    reboot   = true
  }
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.this]
  endpoint             = aws_instance.talos.public_ip
  node                 = aws_instance.talos.private_ip
  client_configuration = talos_machine_secrets.this.client_configuration
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  endpoint             = aws_instance.talos.public_ip
  node                 = aws_instance.talos.private_ip
  client_configuration = talos_machine_secrets.this.client_configuration
}
