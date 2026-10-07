# ---------------------------------------------------------------------------
# 1. Official Talos AMI for this region/arch (workers may use another
#    architecture than the control plane)
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
  # above baseline. "standard" throttles instead.
  burstable = startswith(var.instance_type, "t")
}

# ---------------------------------------------------------------------------
# 2. The EC2 instances - boot the Talos AMI into maintenance mode
# ---------------------------------------------------------------------------
resource "aws_instance" "worker" {
  count = var.worker_count

  ami           = local.ami_id
  instance_type = var.instance_type

  subnet_id                   = var.subnet_id
  associate_public_ip_address = true # needed to apply the config from outside the VPC
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

  tags = merge(var.tags, { Name = "${var.cluster_name}-worker-${count.index}" })
}

# ---------------------------------------------------------------------------
# 3. Talos: worker config -> apply. The node then joins on its own.
# ---------------------------------------------------------------------------
# Workers reach the control plane on its private IP: inside the VPC that is
# covered by the node-to-node rule of the security group, the public IP is not.
data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  machine_type       = "worker"
  cluster_endpoint   = "https://${var.control_plane_private_ip}:6443"
  machine_secrets    = var.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat([
    yamlencode({
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

# endpoint = where we connect, node = who the request is for. A worker in
# maintenance mode only answers on its own address, so the endpoint is the
# worker itself, not the control plane.
# No reset on destroy: the instance is terminated. Its Node object stays in
# Kubernetes as NotReady until `kubectl delete node` removes it.
resource "talos_machine_configuration_apply" "worker" {
  count = var.worker_count

  client_configuration        = var.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  endpoint                    = aws_instance.worker[count.index].public_ip
  node                        = aws_instance.worker[count.index].private_ip
}
