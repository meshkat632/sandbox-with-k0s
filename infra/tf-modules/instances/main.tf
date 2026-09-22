resource "aws_instance" "this" {
  count = var.instance_count

  launch_template {
    id      = var.launch_template_id
    version = var.launch_template_version
  }

  subnet_id = var.subnet_ids[count.index % length(var.subnet_ids)]

  tags = merge({ Name = "${var.name}-${count.index + 1}" }, var.tags)
}
