# ---------------------------------------------------------------------------
# 0. Look up caller IP if allowed_cidr not given
# ---------------------------------------------------------------------------
data "http" "myip" {
  count = var.allowed_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com/"
}

locals {
  allowed_cidr  = coalesce(var.allowed_cidr, "${chomp(data.http.myip[0].response_body)}/32")
  talos_arch    = var.amd64 ? "amd64" : "arm64"
  instance_type = var.amd64 ? var.instance_type : replace(var.instance_type, "t3.", "t4g.")
}

# ---------------------------------------------------------------------------
# 1. Default VPC + a public subnet in it
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# ---------------------------------------------------------------------------
# 2. Official Talos AMI for this region/arch
# ---------------------------------------------------------------------------
data "aws_region" "current" {}

data "http" "cloud_images" {
  url = "https://github.com/siderolabs/talos/releases/download/${var.talos_semver}/cloud-images.json"
}

locals {
  ami_id = coalesce(var.ami_id, [
    for img in jsondecode(data.http.cloud_images.response_body) :
    img.id
    if img.region == data.aws_region.current.region && img.arch == local.talos_arch
  ][0])
}

# ---------------------------------------------------------------------------
# 3. Security group - Talos + Kubernetes API from allowed_cidr, all traffic
#    between the nodes themselves
# ---------------------------------------------------------------------------
resource "aws_security_group" "talos" {
  name        = "${var.cluster_name}-sg"
  description = "Single-node Talos cluster"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Talos API (talosctl / TF provider)"
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  ingress {
    description = "Node to node (workers, control plane, pod network)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "All outbound (pull images, join endpoints, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-sg" })
}

# ---------------------------------------------------------------------------
# 4. The EC2 instances - boot the Talos AMI into maintenance mode
# ---------------------------------------------------------------------------
resource "aws_instance" "talos" {
  ami           = local.ami_id
  instance_type = local.instance_type

  subnet_id                   = data.aws_subnets.default.ids[0]
  associate_public_ip_address = true # ephemeral public IP, no Elastic IP
  vpc_security_group_ids      = [aws_security_group.talos.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.disk_size
    delete_on_termination = true
  }

  tags = merge(var.tags, { Name = var.cluster_name })
}

resource "aws_instance" "worker" {
  count = var.worker_count

  ami           = local.ami_id
  instance_type = local.instance_type

  subnet_id                   = data.aws_subnets.default.ids[0]
  associate_public_ip_address = true # needed to apply the config from outside the VPC
  vpc_security_group_ids      = [aws_security_group.talos.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.disk_size
    delete_on_termination = true
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-worker-${count.index}" })
}

# ---------------------------------------------------------------------------
# 5. Talos: secrets -> config -> apply -> bootstrap -> kubeconfig
# ---------------------------------------------------------------------------
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

locals {
  # Pin the installer to the AMI's Talos release and the Nitro root disk
  # (the provider default is its own bundled version on /dev/sda)
  install_patch = yamlencode({
    machine = {
      install = {
        image = "ghcr.io/siderolabs/installer:${var.talos_semver}"
        disk  = "/dev/nvme0n1"
      }
    }
  })
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = "https://${aws_instance.talos.public_ip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    # Let the control plane run workloads (it is the only node by default)
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
      }
    }),
    local.install_patch,
  ]
}

# Workers reach the control plane on its private IP: inside the VPC that is
# covered by the node-to-node rule, while the public IP is not.
data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  machine_type       = "worker"
  cluster_endpoint   = "https://${aws_instance.talos.private_ip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [local.install_patch]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [aws_instance.talos.public_ip]
  nodes                = concat([aws_instance.talos.private_ip], aws_instance.worker[*].private_ip)
}

# endpoint = where we connect, node = who the request is for. The node must be
# the private IP: apid forwards to it, and the node can't reach its own public
# IP through the security group.
resource "talos_machine_configuration_apply" "this" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
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

# Workers are terminated with the cluster, so no reset on destroy.
resource "talos_machine_configuration_apply" "worker" {
  count = var.worker_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  endpoint                    = aws_instance.worker[count.index].public_ip
  node                        = aws_instance.worker[count.index].private_ip
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