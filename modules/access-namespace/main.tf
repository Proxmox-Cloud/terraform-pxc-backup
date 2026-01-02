resource "kubernetes_namespace" "backup" {
  metadata {
    name = "pve-cloud-backup"
  }
}

# cluster admin access for backup tool 
# todo: restrict access to read only and what the fetcher actually needs
resource "kubernetes_cluster_role_binding" "default_fetcher_sa_admin" {
  metadata {
    name = "pve-cloud-backup-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace.backup.metadata[0].name
  }
}

output "namespace" {
  value = kubernetes_namespace.backup.metadata[0].name
}

data "pxc_ceph_access" "ceph_access" {}

# create config map for the backupper
resource "kubernetes_config_map" "ceph_config" {
  metadata {
    name = "ceph-config"
    namespace = kubernetes_namespace.backup.metadata[0].name
  }

  data = {
    "ceph.conf" = data.pxc_ceph_access.ceph_access.ceph_conf
  }
}

resource "kubernetes_secret" "ceph_secrets" {
  metadata {
    name = "ceph-secrets"
    namespace = kubernetes_namespace.backup.metadata[0].name
  }
  data = {
    "ceph-admin-keyring" = data.pxc_ceph_access.ceph_access.admin_keyring
  }
}
