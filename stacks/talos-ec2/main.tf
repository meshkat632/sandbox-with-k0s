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

  # Machine
  instance_type = try(local.machine.instanceType, "c7i-flex.large")
  disk_size     = try(local.machine.rootVolume.size, 20)
  arch          = can(regex("^[a-z]+[0-9]+[a-z]*g[a-z]*\\.", local.instance_type)) ? "arm64" : "amd64"

  # Free-tier eligible (accounts created on/after 2025-07-15) AND big enough
  # for a Talos control plane. t3.micro / t4g.micro (1 GiB) are free but
  # too small to run Talos.
  free_tier_instance_types = ["c7i-flex.large", "m7i-flex.large", "t3.small", "t4g.small"]

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
      condition     = local.disk_size <= 30
      error_message = "cluster.yaml: rootVolume.size must be <= 30 GiB to stay in the EBS free tier."
    }
    precondition {
      condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", local.talos_semver))
      error_message = "cluster.yaml: controlPlaneConfig.talosVersion must be an exact release like v1.11.2."
    }
    precondition {
      condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", local.kubernetes_version))
      error_message = "cluster.yaml: controlPlane.version must look like v1.34.1."
    }
  }
}

module "networking" {
  source = "./modules/networking"

  cluster_name       = local.cluster_name
  http_ingress_cidrs = coalesce(try(local.infra.network.httpIngress.allowedCIDRBlocks, null), [])
  tags               = local.tags
}

module "talos" {
  source = "./modules/talos"

  subnet_id         = module.networking.subnet_id
  security_group_id = module.networking.security_group_id

  cluster_name       = local.cluster_name
  talos_version      = local.talos_version
  talos_semver       = local.talos_semver
  kubernetes_version = local.kubernetes_version

  arch          = local.arch
  instance_type = local.instance_type
  disk_size     = local.disk_size
  tags          = local.tags

  config_patches = local.config_patches
}
