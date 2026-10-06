module "talos_single" {
  source = "../../"

  cluster_name = var.name
  worker_count = var.worker_count

  http_ingress_cidrs = var.http_ingress_cidrs

  # Optional overrides:
  # instance_type    = "t3.xlarge"
  # disk_size        = 150
  # allowed_cidr     = "203.0.113.10/32"
  # talos_semver     = "v1.12.6"   # used to pick the AMI
}

output "public_ip" {
  value = module.talos_single.public_ip
}

output "worker_public_ips" {
  value = module.talos_single.worker_public_ips
}

output "node_count" {
  value = module.talos_single.node_count
}

output "kubeconfig" {
  value     = module.talos_single.kubeconfig
  sensitive = true
}