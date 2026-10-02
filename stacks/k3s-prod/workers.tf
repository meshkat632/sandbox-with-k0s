# ---------------------------------------------------------------------------
# Worker node pools
#
# One Auto Scaling group of K3s agents per entry in var.node_pools, spread over
# the private subnets. Agents register with server 0 and are labelled
# node-pool=<pool name> and compute-class=<the pool's compute_class>, so a
# workload can ask for a class of machine instead of naming a pool:
#   nodeSelector: { compute-class: general-purpose }
# Pools with kata = true can also run Kata Containers pods (see kata.tf).
#
# Changing a pool (instance type, labels, K3s version, ...) only affects NEW
# instances; running ones are never replaced behind your back. Roll a pool with
#   aws autoscaling start-instance-refresh --auto-scaling-group-name <name>-worker-<pool>
# Nothing drains or deletes a node when its instance goes away: drain it first,
# and `kubectl delete node` the NotReady leftover afterwards.
# ---------------------------------------------------------------------------
data "aws_default_tags" "current" {}

# --- Instance role: Session Manager only (no access to the etcd snapshot bucket) ---
resource "aws_iam_role" "k3s_worker" {
  name               = "${var.name}-k3s-worker"
  assume_role_policy = data.aws_iam_policy_document.k3s_assume.json
}

resource "aws_iam_role_policy_attachment" "k3s_worker_ssm" {
  role       = aws_iam_role.k3s_worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "k3s_worker" {
  name = "${var.name}-k3s-worker"
  role = aws_iam_role.k3s_worker.name
}

# --- One launch template + Auto Scaling group per pool -----------------------
resource "aws_launch_template" "worker" {
  for_each = var.node_pools

  name                   = "${var.name}-worker-${each.key}"
  image_id               = data.aws_ami.ubuntu.id
  instance_type          = each.value.instance_type
  vpc_security_group_ids = [aws_security_group.k3s.id]
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.k3s_worker.name
  }

  # Kata runs each pod in a VM, so the node needs KVM. Bare-metal types have it anyway.
  dynamic "cpu_options" {
    for_each = each.value.kata && !endswith(each.value.instance_type, ".metal") ? [1] : []

    content {
      nested_virtualization = "enabled"
    }
  }

  block_device_mappings {
    device_name = data.aws_ami.ubuntu.root_device_name

    ebs {
      volume_size = each.value.disk_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/scripts/userdata-agent.sh.tftpl", {
    k3s_version = var.k3s_version
    k3s_token   = random_password.k3s_token.result
    server0_ip  = local.server0_ip
    kata        = each.value.kata
    node_labels = [for k, v in merge(
      each.value.labels,
      { "node-pool" = each.key, "compute-class" = each.value.compute_class },
      each.value.kata ? { "kata" = "true" } : {},
    ) : "${k}=${v}"]
    node_taints = each.value.taints
  }))

  # Provider default_tags do not reach instances launched by an Auto Scaling group.
  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume"])

    content {
      resource_type = tag_specifications.value
      tags = merge(data.aws_default_tags.current.tags, {
        Name = "${var.name}-worker-${each.key}"
        Role = "k3s-worker"
        Pool = each.key
      })
    }
  }

  tags = { Name = "${var.name}-worker-${each.key}" }
}

resource "aws_autoscaling_group" "worker" {
  for_each = var.node_pools

  name                = "${var.name}-worker-${each.key}"
  min_size            = each.value.size
  max_size            = each.value.size
  desired_capacity    = each.value.size
  vpc_zone_identifier = [for s in aws_subnet.private : s.id]

  launch_template {
    id      = aws_launch_template.worker[each.key].id
    version = aws_launch_template.worker[each.key].latest_version
  }

  # Don't wait for the instances. When the instance profile is brand new, the first
  # launches fail with "Authentication Failure" until IAM catches up; the group retries
  # by itself, but Terraform would see the failed attempt and mark the group tainted.
  wait_for_capacity_timeout = "0"

  # Agents install K3s through the NAT gateway and join server 0.
  depends_on = [
    aws_instance.k3s_server,
    aws_route_table_association.private,
  ]
}
