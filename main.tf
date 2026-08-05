data "pxc_ssh_key" "host_rsa" {
  key_type = "PVE_HOST_RSA"
}

data "pxc_ssh_key" "automation" {
  key_type = "AUTOMATION"
}

data "pxc_cloud_file_secret" "patroni" {
  secret_name = "patroni.pass"
}

data "pxc_cloud_secret" "bdd_tls_ca" {
  secret_name = "${var.bdd_stack_name}-bdd-tls-certs"
}

data "pxc_pve_host" "host" {
}

# todo: ceph presence should be auto detected and made optional
# for proxmox clusters with zfs only storage for k8s
module "access_namespace" {
  source = "./modules/access-namespace"
  enable_ceph_csi_backups = var.enable_ceph_csi_backups
}

data "pxc_cloud_self" "self" {}

locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)

  k8s_stack_fqdn = "${data.pxc_cloud_self.self.stack_name}.${local.cluster_vars.pve_cloud_domain}"
}

# create config map for the backupper
resource "kubernetes_config_map" "fetcher_config" {
  metadata {
    name = "fetcher-config"
    namespace = module.access_namespace.namespace
  }

  data = {
    "backup-conf.yaml" = yamlencode({
      patroni_stack = var.patroni_stack
      k8s_stack = local.k8s_stack_fqdn
      k8s_namespaces = var.k8s_namespaces
      git_repos = var.git_repo_ssh_key != null ? var.git_repos : []
      nextcloud_files = var.nextcloud_url != null && var.nextcloud_user != null && var.nextcloud_pass != null ? var.nextcloud_files : []
    })
  }
}

resource "kubernetes_secret" "fetcher_secrets" {
  metadata {
    name = "fetcher-secrets"
    namespace =  module.access_namespace.namespace
  }
  data = merge({
    "pve-id-rsa" = data.pxc_ssh_key.host_rsa.key
    "qemu-id"= data.pxc_ssh_key.automation.key
  },
  var.patroni_stack != null ? {
    "patroni-pass" = data.pxc_cloud_file_secret.patroni.secret
  } : {},
  var.nextcloud_pass != null ? {
    "nextcloud-pass" = var.nextcloud_pass
  }: {},
  var.git_repo_ssh_key != null && var.git_repo_ssh_key_type != null ? {
    "id-git" = var.git_repo_ssh_key
  } : {}
  )
}

resource "kubernetes_secret" "fetcher_tls_ca" {
  metadata {
    name = "fetcher-tls-ca"
    namespace =  module.access_namespace.namespace
  }
  data = {
    "ca_cert.crt" = jsondecode(data.pxc_cloud_secret.bdd_tls_ca.secret_data)["ca_cert.crt"]
  }
}

resource "kubernetes_cron_job_v1" "fetcher_cron" {
  metadata {
    name      = "fetcher-cron"
    namespace = module.access_namespace.namespace
  }

  spec {
    schedule = var.cron_schedule

    job_template {
      metadata {}

      spec {
        backoff_limit = 0

        template {
          metadata {
            annotations = {
              "kubernetes.io/egress-bandwidth" = var.bandwidth_limitation
              "kubernetes.io/ingress-bandwidth" = var.bandwidth_limitation
            }
          }

          spec {
            restart_policy = "Never"

            node_selector       = var.node_selector

            dynamic "toleration" {
              for_each = var.tolerations != null ? var.tolerations : []
              content {
                key                = lookup(toleration.value, "key", null)
                operator           = lookup(toleration.value, "operator", null)
                value              = lookup(toleration.value, "value", null)
                effect             = lookup(toleration.value, "effect", null)
              }
            }

            volume {
              name = "fetcher-config"

              config_map {
                name = "fetcher-config"
              }
            }

            dynamic "volume" {
              for_each = var.enable_ceph_csi_backups ? [1] : []

              content {
                name = "ceph-config"

                config_map {
                  name = "ceph-config"
                }
              }
            }

            dynamic "volume" {
              for_each = var.enable_ceph_csi_backups ? [1] : []

              content {
                name = "ceph-secrets"

                secret {
                  secret_name = "ceph-secrets"
                }
              }
            }

            volume {
              name = "fetcher-secrets"

              secret {
                secret_name  = "fetcher-secrets"
                default_mode = "0400"
              }
            }

            volume {
              name = "fetcher-tls-ca"

              secret {
                secret_name = "fetcher-tls-ca"
              }
            }

            container {
              name              = "fetcher"
              image             = "${local.backup_image_base}:${local.backup_image_version}"
              image_pull_policy = "Always"

              args = ["fetcher"]

              env {
                name  = "BDD_HOST"
                value = var.backup_daemon_address
              }

              env {
                name  = "BDD_CA_CERT_PATH"
                value = "/opt/bdd_ca.crt"
              }

              env {
                name  = "PROXMOXER_HOST"
                value = data.pxc_pve_host.host.pve_host
              }

              env {
                name  = "PROXMOXER_USER"
                value = "root"
              }

              env {
                name  = "QEMU_ADMIN_USER"
                value = var.qemu_admin_user
              }

              dynamic "env" {
                for_each = var.patroni_stack != null ? [1] : []

                content {
                  name = "PATRONI_PASS"

                  value_from {
                    secret_key_ref {
                      name = "fetcher-secrets"
                      key  = "patroni-pass"
                    }
                  }
                }
              }

              dynamic "env" {
                for_each = (
                  var.nextcloud_url != null &&
                  var.nextcloud_user != null &&
                  var.nextcloud_pass != null
                ) ? [1] : []

                content {
                  name  = "NEXTCLOUD_USER"
                  value = var.nextcloud_user
                }
              }

              dynamic "env" {
                for_each = (
                  var.nextcloud_url != null &&
                  var.nextcloud_user != null &&
                  var.nextcloud_pass != null
                ) ? [1] : []

                content {
                  name  = "NEXTCLOUD_BASE"
                  value = var.nextcloud_url
                }
              }
              dynamic "volume_mount" {
                for_each = var.enable_ceph_csi_backups ? [1] : []

                content {
                  mount_path = "/etc/ceph/ceph.conf"
                  name       = "ceph-config"
                  sub_path   = "ceph.conf"
                }
              }

              dynamic "volume_mount" {
                for_each = var.enable_ceph_csi_backups ? [1] : []

                content {
                  mount_path = "/etc/pve/priv/ceph.client.admin.keyring"
                  name       = "ceph-secrets"
                  sub_path   = "ceph-admin-keyring"
                }
              }

              volume_mount {
                mount_path = "/opt/backup-conf.yaml"
                name       = "fetcher-config"
                sub_path   = "backup-conf.yaml"
              }

              volume_mount {
                mount_path = "/root/.ssh/id_rsa"
                name       = "fetcher-secrets"
                sub_path   = "pve-id-rsa"
              }

              volume_mount {
                mount_path = "/opt/id_proxmox"
                name       = "fetcher-secrets"
                sub_path   = "pve-id-rsa"
              }

              volume_mount {
                mount_path = "/opt/id_qemu"
                name       = "fetcher-secrets"
                sub_path   = "qemu-id"
              }

              dynamic "volume_mount" {
                for_each = (
                  var.nextcloud_url != null &&
                  var.nextcloud_user != null &&
                  var.nextcloud_pass != null
                ) ? [1] : []

                content {
                  mount_path = "/opt/nextcloud.pass"
                  name       = "fetcher-secrets"
                  sub_path   = "nextcloud-pass"
                }
              }

              dynamic "volume_mount" {
                for_each = (
                  var.git_repo_ssh_key != null &&
                  var.git_repo_ssh_key_type != null
                ) ? [1] : []

                content {
                  mount_path = "/root/.ssh/id_${var.git_repo_ssh_key_type}"
                  name       = "fetcher-secrets"
                  sub_path   = "id-git"
                }
              }

              volume_mount {
                mount_path = "/opt/bdd_ca.crt"
                name       = "fetcher-tls-ca"
                sub_path   = "ca_cert.crt"
              }
            }
          }
        }
      }
    }
  }
}
