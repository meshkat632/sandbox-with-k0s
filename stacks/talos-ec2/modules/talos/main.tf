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

  # With a load balancer its fixed IP is the API endpoint; without one it is
  # the public IP of the only control plane node
  cluster_endpoint = (
    var.load_balancer_enabled
    ? "https://${var.load_balancer_ip}:6443"
    : "https://${aws_instance.talos[0].public_ip}:6443"
  )

  data_disk_count = var.data_disk_size > 0 ? var.control_plane_count : 0
  lb_node_count   = var.load_balancer_enabled ? var.control_plane_count : 0
  lb_ports        = [6443, 80, 443]
}

# ---------------------------------------------------------------------------
# 2. The EC2 instances - boot the Talos AMI into maintenance mode
# ---------------------------------------------------------------------------
resource "aws_instance" "talos" {
  count = var.control_plane_count

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

  tags = merge(var.tags, {
    Name = var.control_plane_count > 1 ? "${var.cluster_name}-${count.index}" : var.cluster_name
  })
}

# A single-node state from before control_plane_count keeps its instance
moved {
  from = aws_instance.talos
  to   = aws_instance.talos[0]
}

moved {
  from = talos_machine_configuration_apply.this
  to   = talos_machine_configuration_apply.this[0]
}

# Separate disk per node for persistent volumes. Attached instead of declared
# on the instance, so adding or resizing it does not replace the node.
resource "aws_ebs_volume" "data" {
  count = local.data_disk_count

  availability_zone = aws_instance.talos[count.index].availability_zone
  type              = "gp3"
  size              = var.data_disk_size

  tags = merge(var.tags, {
    Name = var.control_plane_count > 1 ? "${var.cluster_name}-${count.index}-data" : "${var.cluster_name}-data"
  })
}

resource "aws_volume_attachment" "data" {
  count = local.data_disk_count

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data[count.index].id
  instance_id = aws_instance.talos[count.index].id

  # Talos keeps the disk mounted, so a normal detach hangs on destroy
  force_detach = true
}

# ---------------------------------------------------------------------------
# 3. Load balancer (optional): every control plane node is a target for the
#    API and for the ingress controller
# ---------------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "api" {
  count = local.lb_node_count

  target_group_arn = var.target_group_arns["api"]
  target_id        = aws_instance.talos[count.index].id
}

resource "aws_lb_target_group_attachment" "http" {
  count = local.lb_node_count

  target_group_arn = var.target_group_arns["http"]
  target_id        = aws_instance.talos[count.index].id
}

resource "aws_lb_target_group_attachment" "https" {
  count = local.lb_node_count

  target_group_arn = var.target_group_arns["https"]
  target_id        = aws_instance.talos[count.index].id
}

# The nodes reach the load balancer's public IP from their own public IPs
# (the API endpoint, and cert-manager checking its HTTP-01 challenges)
resource "aws_vpc_security_group_ingress_rule" "lb_from_node" {
  count = local.lb_node_count * length(local.lb_ports)

  security_group_id = var.load_balancer_security_group_id
  description       = "From control plane node ${floor(count.index / length(local.lb_ports))}"
  ip_protocol       = "tcp"
  from_port         = local.lb_ports[count.index % length(local.lb_ports)]
  to_port           = local.lb_ports[count.index % length(local.lb_ports)]
  cidr_ipv4         = "${aws_instance.talos[floor(count.index / length(local.lb_ports))].public_ip}/32"
}

# ---------------------------------------------------------------------------
# 4. Talos: secrets -> config -> apply -> bootstrap -> kubeconfig
# ---------------------------------------------------------------------------
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "this" {
  cluster_name       = var.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat([
    yamlencode({
      # Control plane nodes keep their node-role.kubernetes.io/control-plane
      # NoSchedule taint: only pods that tolerate it run here
      cluster = {
        allowSchedulingOnControlPlanes = false
      }
      # Pin the installer to the AMI's Talos release and the Nitro root disk
      # (the provider default is its own bundled version on /dev/sda)
      machine = {
        install = {
          image = "ghcr.io/siderolabs/installer:${var.talos_semver}"
          disk  = "/dev/nvme0n1"
        }
        nodeLabels = {
          "cluster.local/role" = "control-plane"
        }
      }
    }),
    ],
    # Talos formats the data disk and mounts it at /var/mnt/local-storage
    var.data_disk_size > 0 ? [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = "local-storage"
      provisioning = {
        diskSelector = { match = "!system_disk" }
        minSize      = "1GiB"
      }
    })] : [],
  var.config_patches)
}

# The Talos API is not load balanced: talosctl tries the endpoints in turn.
# One default node, because commands like `talosctl kubeconfig` take only one;
# address another with -n <private ip>.
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = aws_instance.talos[*].public_ip
  nodes                = [aws_instance.talos[0].private_ip]
}

# endpoint = where we connect, node = who the request is for. The node must be
# the private IP: apid forwards to it, and the node can't reach its own public
# IP through the security group.
resource "talos_machine_configuration_apply" "this" {
  count = var.control_plane_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this.machine_configuration
  endpoint                    = aws_instance.talos[count.index].public_ip
  node                        = aws_instance.talos[count.index].private_ip

  # No reset on destroy: the instance is terminated anyway, and a reset needs
  # the Talos API, so a destroy from another IP than the one in the security
  # group would hang. The price: lowering control_plane_count does not take
  # the removed nodes out of etcd first.
}

# Only the first node is bootstrapped; the others join its etcd on their own
resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.this]
  endpoint             = aws_instance.talos[0].public_ip
  node                 = aws_instance.talos[0].private_ip
  client_configuration = talos_machine_secrets.this.client_configuration
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  endpoint             = aws_instance.talos[0].public_ip
  node                 = aws_instance.talos[0].private_ip
  client_configuration = talos_machine_secrets.this.client_configuration
}

# ---------------------------------------------------------------------------
# 5. Publish the Talos client config, so the kubeconfig can be fetched from
#    the instance without Terraform (make kubeconfig). SecureString standard
#    parameters are free.
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "talosconfig" {
  name  = "/talos/${var.cluster_name}/talosconfig"
  type  = "SecureString"
  value = data.talos_client_configuration.this.talos_config
  tags  = var.tags
}
