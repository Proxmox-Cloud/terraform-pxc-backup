
module "access_namespace" {
  source = "../access-namespace"
  enable_ceph_csi_backups = false # no ceph support
}

# backup to a pxc linked bdd server
data "pxc_cloud_secret" "bdd_discovery" {
  secret_name = "${var.bdd_stack_name}-bdd-tls-discovery"
}

data "pxc_cloud_self" "self" {}

locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)

  k8s_stack_fqdn = "${data.pxc_cloud_self.self.stack_name}.${local.cluster_vars.pve_cloud_domain}"
}

# ssh key to access the k0s hosts
data "pxc_cloud_secret" "k0s_edge_host_key" {
  secret_name = "${local.k8s_stack_fqdn}-k0s-edge-key"
}

resource "kubernetes_config_map" "fetcher_config" {
  metadata {
    name = "fetcher-config"
    namespace = module.access_namespace.namespace
  }

  data = {
    "backup-conf.yaml" = yamlencode({
      k8s_stack = local.k8s_stack_fqdn
      k8s_namespaces = var.k8s_namespaces
    })
  }
}

resource "kubernetes_secret" "fetcher_secrets" {
  metadata {
    name = "fetcher-secrets"
    namespace =  module.access_namespace.namespace
  }
  data = {
    "ext-id" = jsondecode(data.pxc_cloud_secret.k0s_edge_host_key.secret_data)["id_ed25519"]
  }
}

resource "kubernetes_secret" "fetcher_tls_ca" {
  metadata {
    name = "fetcher-tls-ca"
    namespace =  module.access_namespace.namespace
  }
  data = {
    "ca_cert.crt" = jsondecode(data.pxc_cloud_secret.bdd_discovery.secret_data)["ca_cert.crt"]
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


            volume {
              name = "fetcher-config"

              config_map {
                name = "fetcher-config"
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

              args = ["ext-zfs"]

              env {
                name  = "BDD_HOST"
                value = var.backup_daemon_address != null ? var.backup_daemon_address : jsondecode(data.pxc_cloud_secret.bdd_discovery.secret_data)["server_int_ip"]
              }

              env {
                name  = "BDD_CA_CERT_PATH"
                value = "/opt/bdd_ca.crt"
              }

              # todo: var name can be made more generic inside backupper
              env {
                name  = "QEMU_ADMIN_USER"
                value = var.k0s_admin_user
              }

              volume_mount {
                mount_path = "/opt/backup-conf.yaml"
                name       = "fetcher-config"
                sub_path   = "backup-conf.yaml"
              }

              volume_mount {
                mount_path = "/opt/id_ext"
                name       = "fetcher-secrets"
                sub_path   = "ext-id"
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
