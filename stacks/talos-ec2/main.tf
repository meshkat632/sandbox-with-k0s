# ---------------------------------------------------------------------------
# All configuration comes from the Cluster object in cluster.yaml
# ---------------------------------------------------------------------------
locals {
  cluster = yamldecode(file("${path.module}/cluster.yaml"))

  spec    = local.cluster.spec
  infra   = local.spec.infrastructure
  cp      = local.spec.controlPlane
  machine = local.cp.machineTemplate.spec
  talos   = local.cp.controlPlaneConfig

  cluster_name = local.cluster.metadata.name
  region       = local.infra.region
  tags         = try(local.infra.additionalTags, {})

  # Versions: Talos contract (v1.11) is derived from the exact release
  talos_semver       = local.talos.talosVersion
  talos_version      = regex("^v[0-9]+\\.[0-9]+", local.talos_semver)
  kubernetes_version = trimprefix(local.cp.version, "v")

  # Control plane: 1 node, or 3/5 behind a load balancer
  control_plane_count   = try(local.cp.replicas, 1)
  load_balancer_enabled = try(local.infra.controlPlaneLoadBalancer.enabled, false)

  # Machine
  instance_type  = try(local.machine.instanceType, "c7i-flex.large")
  disk_size      = try(local.machine.rootVolume.size, 20)
  data_disk_size = try(local.machine.dataVolume.size, 0)
  arch           = can(regex("^[a-z]+[0-9]+[a-z]*g[a-z]*\\.", local.instance_type)) ? "arm64" : "amd64"

  # Free-tier eligible (accounts created on/after 2025-07-15) AND big enough
  # for a Talos control plane. t3.micro / t4g.micro (1 GiB) are free but
  # too small to run Talos.
  free_tier_instance_types = ["c7i-flex.large", "m7i-flex.large", "t3.small", "t4g.small"]

  # Workers (optional): same Talos and Kubernetes versions as the control plane
  workers              = try(local.spec.workers, {})
  worker_count         = try(local.workers.replicas, 0)
  worker_machine       = try(local.workers.machineTemplate.spec, {})
  worker_instance_type = try(local.worker_machine.instanceType, local.instance_type)
  worker_disk_size     = try(local.worker_machine.rootVolume.size, 20)
  worker_arch          = can(regex("^[a-z]+[0-9]+[a-z]*g[a-z]*\\.", local.worker_instance_type)) ? "arm64" : "amd64"

  # Add-ons to install: a list of script names from addons/ (missing = none)
  addons_raw   = try(local.spec.addons.install, null)
  addons       = local.addons_raw == null ? [] : try([for a in local.addons_raw : tostring(a)], [])
  known_addons = [for f in fileset("${path.module}/addons", "*.sh") : trimsuffix(f, ".sh")]

  # Everything `make addons` runs or reads
  addon_files = setunion(fileset(path.module, "addons/**"), ["Makefile"])

  # Optional, not in cluster.yaml by default: controlPlaneConfig.strategicPatches
  config_patches = [for p in coalesce(try(local.talos.strategicPatches, null), []) : yamlencode(p)]
}

# Validation of cluster.yaml - fails the plan
resource "terraform_data" "cluster_spec" {
  lifecycle {
    precondition {
      condition     = local.cluster.kind == "Cluster"
      error_message = "cluster.yaml: kind must be Cluster."
    }
    precondition {
      condition     = contains(local.free_tier_instance_types, local.instance_type)
      error_message = "cluster.yaml: instanceType must be a free-tier type that can run Talos: ${join(", ", local.free_tier_instance_types)}."
    }
    precondition {
      condition     = contains([1, 3, 5], local.control_plane_count)
      error_message = "cluster.yaml: controlPlane.replicas must be 1, 3 or 5: etcd needs an odd number of members to keep a majority."
    }
    precondition {
      condition     = local.control_plane_count == 1 || local.load_balancer_enabled
      error_message = "cluster.yaml: more than one control plane node needs infrastructure.controlPlaneLoadBalancer.enabled: true."
    }
    # A single node is meant to fit the free tier; several nodes never do
    precondition {
      condition     = local.control_plane_count > 1 || local.disk_size + local.data_disk_size <= 30
      error_message = "cluster.yaml: rootVolume.size + dataVolume.size must be <= 30 GiB to stay in the EBS free tier."
    }
    precondition {
      condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", local.talos_semver))
      error_message = "cluster.yaml: controlPlaneConfig.talosVersion must be an exact release like v1.11.2."
    }
    precondition {
      condition     = can(local.worker_count >= 0 && floor(local.worker_count) == local.worker_count)
      error_message = "cluster.yaml: workers.replicas must be a whole number >= 0."
    }
    precondition {
      condition     = local.worker_count == 0 || contains(local.free_tier_instance_types, local.worker_instance_type)
      error_message = "cluster.yaml: workers instanceType must be one of: ${join(", ", local.free_tier_instance_types)}."
    }
    precondition {
      condition     = local.addons_raw == null || can([for a in local.addons_raw : tostring(a)])
      error_message = "cluster.yaml: addons.install must be a list of add-on names."
    }
    precondition {
      condition     = length(setsubtract(local.addons, local.known_addons)) == 0
      error_message = "cluster.yaml: unknown add-on in addons.install: ${join(", ", setsubtract(local.addons, local.known_addons))}. Known: ${join(", ", local.known_addons)}."
    }
    precondition {
      condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", local.kubernetes_version))
      error_message = "cluster.yaml: controlPlane.version must look like v1.34.1."
    }
  }
}

module "networking" {
  source = "./modules/networking"

  cluster_name          = local.cluster_name
  http_ingress_cidrs    = coalesce(try(local.infra.network.httpIngress.allowedCIDRBlocks, null), [])
  load_balancer_enabled = local.load_balancer_enabled
  tags                  = local.tags
}

module "talos" {
  source = "./modules/talos"

  subnet_id         = module.networking.subnet_id
  security_group_id = module.networking.security_group_id

  load_balancer_enabled           = local.load_balancer_enabled
  load_balancer_ip                = module.networking.load_balancer_ip
  load_balancer_security_group_id = module.networking.load_balancer_security_group_id
  target_group_arns               = module.networking.target_group_arns

  cluster_name       = local.cluster_name
  talos_version      = local.talos_version
  talos_semver       = local.talos_semver
  kubernetes_version = local.kubernetes_version

  control_plane_count = local.control_plane_count

  arch           = local.arch
  instance_type  = local.instance_type
  disk_size      = local.disk_size
  data_disk_size = local.data_disk_size
  tags           = local.tags

  config_patches = local.config_patches
}

# Extra worker nodes (workers.replicas in cluster.yaml, 0 = single node)
module "workers" {
  source = "./modules/workers"

  worker_count = local.worker_count

  subnet_id         = module.networking.subnet_id
  security_group_id = module.networking.security_group_id

  load_balancer_enabled           = local.load_balancer_enabled
  load_balancer_security_group_id = module.networking.load_balancer_security_group_id
  target_group_arns               = module.networking.target_group_arns

  cluster_endpoint     = module.talos.worker_endpoint
  machine_secrets      = module.talos.machine_secrets
  client_configuration = module.talos.client_configuration

  cluster_name       = local.cluster_name
  talos_version      = local.talos_version
  talos_semver       = local.talos_semver
  kubernetes_version = local.kubernetes_version

  arch          = local.worker_arch
  instance_type = local.worker_instance_type
  disk_size     = local.worker_disk_size
  tags          = local.tags
}


/*
# ---------------------------------------------------------------------------
# Add-ons: `make addons` for the ones listed in cluster.yaml, on the machine
# that runs Terraform, which therefore needs aws, talosctl, kubectl, helm and git. The scripts are idempotent.
# Terraform only tracks whether they ran - not what is installed in the
# cluster - and destroy does not uninstall them (the node goes away anyway).
# ---------------------------------------------------------------------------
resource "terraform_data" "addons" {
  count = length(local.addons) > 0 ? 1 : 0

  # Run again when the selection or an add-on changes, or when the cluster gets
  # a new address (the sslip.io host names and the wildcard certificate contain it)
  triggers_replace = {
    addons   = join(" ", sort(local.addons))
    endpoint = module.talos.cluster_endpoint
    files    = sha256(join("", [for f in sort(local.addon_files) : filesha256("${path.module}/${f}")]))
  }

  provisioner "local-exec" {
    command     = "make addons ADDONS='${join(" ", local.addons)}'"
    working_dir = path.module
  }

  # The whole module: bootstrap, the published talosconfig and the data disk
  depends_on = [module.talos]
}
*/