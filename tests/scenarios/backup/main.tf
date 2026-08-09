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

# in this the unit test will make modifications
module "backup_source" {
  source = "../deployment"
  namespace = "test-backup-source"
  storage_class_name = "csi-rbd-sc-${local.test_pve_conf["ceph_csi_storage_pool"]}"
}

# print helm release secrets in backup test
resource "pxc_helm_mirror" "nginx_bitnami" {
  source_repository = "https://charts.bitnami.com/bitnami"
  source_name = "bitnami"
  chart = "nginx"
  version = "22.4.2"
}

resource "helm_release" "nginx_test" {
  depends_on = [ module.backup_source ]
  repository = pxc_helm_mirror.nginx_bitnami.repository_out
  chart = pxc_helm_mirror.nginx_bitnami.chart
  version = pxc_helm_mirror.nginx_bitnami.version
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
  source = "../deployment"
  namespace = "test-backup-restore"
  storage_class_name = "csi-rbd-sc-${local.test_pve_conf["ceph_csi_storage_pool"]}"
}

# restore destination for the zfs csi based secondary cluster (cross csi restore test)
module "backup_restore_zfs" {
  source = "../deployment"
  namespace = "test-backup-restore-zfs"
  storage_class_name = "csi-rbd-sc-${local.test_pve_conf["ceph_csi_storage_pool"]}"
}

module "tf_backup"{
  source =  "../../../"
  bdd_stack_name = "pytest-backup-qemu"

  patroni_stack = "ha-postgres.${local.test_pve_conf["cloud_inventory"]["pve_cloud_domain"]}"

  k8s_namespaces = [ "test-backup-source" ]

  bandwidth_limitation = "20M"

  backup_image_base = var.backup_image_base
  backup_image_version = var.backup_image_version

  node_selector = {
    "kubernetes.io/os" = "linux"
  }

  tolerations = [
    {
      "key" = "example"
      "operator" = "Equal"
      "value" = "test"
      "effect" = "NoSchedule"
     }
  ]
}


