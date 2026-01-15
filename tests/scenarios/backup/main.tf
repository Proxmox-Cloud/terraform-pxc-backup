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

provider "pxc" {
  target_pve = "${local.test_pve_conf["pve_test_cluster_name"]}.${local.test_pve_conf["pve_test_cloud_domain"]}"
  k8s_stack_name = "pytest-k8s"
}


# in this the unit test will make modifications
module "backup_source" {
  source = "./deployment"
  namespace = "test-backup-source"
}

# print helm release secrets in backup test
resource "helm_release" "nginx_test" {
  depends_on = [ module.backup_source ]
  repository = "https://charts.bitnami.com/bitnami"
  chart = "nginx"
  version = "22.4.2"
  create_namespace = true
  namespace = "test-backup-source"
  
  name = "nginx"
  values = [
    <<-YAML
      service:
        type: ClusterIP
    YAML
  ]
}

# same deployment that will serve as the restore target namespace
module "backup_restore" {
  source = "./deployment"
  namespace = "test-backup-restore"
}

module "tf_backup"{
  source =  "../../../"
  backup_daemon_address = "main-pytest-backup-lxc.${local.test_pve_conf["pve_test_cloud_domain"]}"
  patroni_stack = "ha-postgres.${local.test_pve_conf["pve_test_cloud_domain"]}"

  k8s_stack = "pytest-k8s.${local.test_pve_conf["pve_test_cloud_domain"]}"
  k8s_namespaces = [ "test-backup-source" ]

  bandwidth_limitation = "20M"

  backup_image_base = var.backup_image_base
  backup_image_version = var.backup_image_version
}


