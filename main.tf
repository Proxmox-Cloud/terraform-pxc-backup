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
    "patroni-pass" = data.pxc_cloud_file_secret.patroni.secret
  },
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


resource "kubernetes_manifest" "fetcher_cron" {
  manifest = yamldecode(templatefile("${path.module}/templates/fetcher-cron.yaml.tpl", {
    namespace              = module.access_namespace.namespace
    cron_schedule          = var.cron_schedule
    bandwidth_limitation   = var.bandwidth_limitation
    backup_image           = local.backup_image_base
    backup_image_version   = local.backup_image_version
    backup_daemon_address  = var.backup_daemon_address
    pve_host               = data.pxc_pve_host.host.pve_host
    qemu_admin_user        = var.qemu_admin_user
    nextcloud_url          = var.nextcloud_url
    nextcloud_user         = var.nextcloud_user
    nextcloud_pass         = var.nextcloud_pass
    git_repo_ssh_key       = var.git_repo_ssh_key
    git_repo_ssh_key_type  = var.git_repo_ssh_key_type
    node_selector          = var.node_selector
    tolerations            = var.tolerations
  }))
}

