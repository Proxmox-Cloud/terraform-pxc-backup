# init core scenario
variable "test_pve_conf" {
  type = string
}

variable "backup_image_base" {
  type = string
  default = null
}

variable "backup_image_version" {
  type = string
  default = null
}

locals {
  test_pve_conf = yamldecode(file(var.test_pve_conf))
}

variable "e2e_kubespray_inv" {
  type = string
}

provider "pxc" {
  inventory = var.e2e_kubespray_inv
}

module "backup_source" {
  source = "../deployment"
  namespace = "test-backup-source"
  storage_class_name = "openebs-zfspv-zvol"
}

# send via mc gateway
data "pxc_cloud_secret" "mc_ext_discovery" {
  secret_name = "external-mc-token"
}

module "tf_backup" {
  source =  "../../../"
  bdd_stack_name = "pytest-backup-qemu"

  # use our gateway
  backup_daemon_address = "https://${jsondecode(data.pxc_cloud_secret.mc_ext_discovery.secret_data).mc_gw_host}"
  mc_ext_token = jsondecode(data.pxc_cloud_secret.mc_ext_discovery.secret_data).token

  enable_ceph_csi_backups = false

  k8s_namespaces = [ "test-backup-source" ]

  bandwidth_limitation = "20M"

  backup_image_base = var.backup_image_base
  backup_image_version = var.backup_image_version

}

module "backup_restore" {
  source = "../deployment"
  namespace = "test-backup-restore"
  storage_class_name = "openebs-zfspv-zvol"
}

# restore destination for primary ceph csi based cluster
module "backup_restore_ceph" {
  source = "../deployment"
  namespace = "test-backup-restore-ceph"
  storage_class_name = "openebs-zfspv-zvol"
}
