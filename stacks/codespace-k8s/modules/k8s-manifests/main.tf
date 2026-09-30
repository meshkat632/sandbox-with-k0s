locals {
  manifests = merge([
    for f in fileset(var.manifests_dir, var.file_pattern) : {
      for m in provider::kubernetes::manifest_decode_multi(file("${var.manifests_dir}/${f}")) :
      "${m.kind}/${m.metadata.name}" => m
    }
  ]...)
}

resource "kubernetes_manifest" "namespaces" {
  for_each = { for k, m in local.manifests : k => m if m.kind == "Namespace" }
  manifest = each.value
}

resource "kubernetes_manifest" "objects" {
  for_each = { for k, m in local.manifests : k => m if m.kind != "Namespace" }
  manifest = each.value

  depends_on = [kubernetes_manifest.namespaces]
}