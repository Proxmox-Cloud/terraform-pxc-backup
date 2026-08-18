variable "enable_ceph_csi_backups" {
  type = bool # same as main module
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
