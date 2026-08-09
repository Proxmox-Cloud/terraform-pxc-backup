
ephemeral "pxc_k0s_kubeconfig" "kubeconfig" {}

locals {
  kubeconfig = yamldecode(ephemeral.pxc_k0s_kubeconfig.kubeconfig.config)
}

provider "kubernetes" {
  client_certificate = base64decode(local.kubeconfig.users[0].user.client-certificate-data)
  client_key = base64decode(local.kubeconfig.users[0].user.client-key-data)
  host = local.kubeconfig.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster.certificate-authority-data)
}
