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

variable "enable_ceph_csi_backups" {
  type = bool # same as main module
}

data "pxc_ceph_access" "ceph_access" {
  count = var.enable_ceph_csi_backups ? 1 : 0
}

# create config map for the backupper
resource "kubernetes_config_map" "ceph_config" {
  count = var.enable_ceph_csi_backups ? 1 : 0
  metadata {
    name = "ceph-config"
    namespace = kubernetes_namespace.backup.metadata[0].name
  }

  data = {
    "ceph.conf" = data.pxc_ceph_access.ceph_access[0].ceph_conf
  }
}

resource "kubernetes_secret" "ceph_secrets" {
  count = var.enable_ceph_csi_backups ? 1 : 0
  metadata {
    name = "ceph-secrets"
    namespace = kubernetes_namespace.backup.metadata[0].name
  }
  data = {
    "ceph-admin-keyring" = data.pxc_ceph_access.ceph_access[0].admin_keyring
  }
}

variable "deploy_restore_secrets" {
  type = string
  description = <<-EOF
    Use this variable to trigger creation needed for restoring backups. This is useful for restore only options where you
    dont want to configure a backup job.
  EOF
  default = null
  validation {
    condition = var.deploy_restore_secrets == null || contains(
      ["kubespray", "k0s-edge"], var.deploy_restore_secrets
    )
    error_message = "Deploy restore secrets options are kubespray, k0s-edge or null!"
  }
}


data "pxc_ssh_key" "automation" {
  count = var.deploy_restore_secrets == "kubespray" ? 1 : 0
  key_type = "AUTOMATION"
}

data "pxc_cloud_self" "self" {}

locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)

  k8s_stack_fqdn = "${data.pxc_cloud_self.self.stack_name}.${local.cluster_vars.pve_cloud_domain}"
}

# ssh key to access the k0s hosts
data "pxc_cloud_secret" "k0s_edge_host_key" {
  count = var.deploy_restore_secrets == "k0s-edge" ? 1 : 0
  secret_name = "${local.k8s_stack_fqdn}-k0s-edge-key"
}

resource "kubernetes_secret" "fetcher_secrets" {
  count = var.deploy_restore_secrets != null ? 1 : 0
  metadata {
    name = "fetcher-secrets"
    namespace = kubernetes_namespace.backup.metadata[0].name
  }
  data = merge(
    var.deploy_restore_secrets == "kubespray" ? {
      "qemu-id" = data.pxc_ssh_key.automation[0].key
    } : {},
    var.deploy_restore_secrets == "k0s_edge" ? {
      "ext-id" = jsondecode(data.pxc_cloud_secret.k0s_edge_host_key[0].secret_data)["id_ed25519"]
    } : {}
  )
}
