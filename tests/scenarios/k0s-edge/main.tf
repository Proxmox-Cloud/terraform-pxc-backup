

variable "backup_image_base" {
  type = string
  default = null
}

variable "backup_image_version" {
  type = string
  default = null
}
variable "e2e_k0s_ext_hosts_inv" {
  type = string
}
provider "pxc" {
  inventory = var.e2e_k0s_ext_hosts_inv
}
variable "test_pve_conf" {
  type = string
}

locals {
  test_pve_conf = yamldecode(file(var.test_pve_conf))
}

module "backup_source" {
  source = "../deployment"
  namespace = "test-backup-source"
  storage_class_name = "openebs-zfspv-zvol"
}

module "tf_backup_edge" {
  source =  "../../../modules/k0s-edge-zfs-localpv"
  # here we do some fuckery for e2e testing. The backup server is running on the same edge
  # kubernetes node that we create the backups from
  bdd_stack_name = "pytest-k0s"

  use_mc_gw_as_host = true

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
