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

module "tf_backup"{
  source =  "../../../"
  backup_daemon_address = "main-pytest-backup-lxc.${local.test_pve_conf["cloud_inventory"]["pve_cloud_domain"]}"
  patroni_stack = "ha-postgres.${local.test_pve_conf["cloud_inventory"]["pve_cloud_domain"]}"
  bdd_stack_name = "pytest-backup-lxc"

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
