provider "aws" {
  region = var.region
}

# Authenticates with the admin client certificate from the kubeconfig the
# instance publishes. Read on every run, so a rebuilt cluster (new CA and
# certificates) is picked up without any change here.
provider "kubernetes" {
  host                   = local.kubeconfig.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  client_certificate     = base64decode(local.kubeconfig.users[0].user["client-certificate-data"])
  client_key             = base64decode(local.kubeconfig.users[0].user["client-key-data"])
}
