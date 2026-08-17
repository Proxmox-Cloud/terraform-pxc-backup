
# we need to do these shenanigans because we cannot pass variables conditionally to this module during tdd
locals {
  backup_image_base = var.backup_image_base == null ? "tobiashvmz/pve-cloud-backup" : var.backup_image_base
  backup_image_version = var.backup_image_version == null ? "3.5.14" : var.backup_image_version
}

variable "backup_image_version" {
  type = string
  description = "Backup image version, doesn't need to be changed usually."
  default = null
}

variable "backup_image_base" {
  type = string
  description = "Backup image base, doesn't need to be changed usually."
  default = null
}

variable "bdd_stack_name" {
  type = string
  description = "Stack name of the backup server used to locate the discovery secret (host address + tls certs)."
}

variable "use_mc_gw_as_host" {
  type = bool
  default = false
  description = <<-EOT
    Will use the dicovery secret external-mc-token to get credentials + multi cloud endpoint. Mutually exclusive with backup_daemon_address.
    You determine the destination of the gateway / cloud + backup server by the initialization of your pxc provider. You should use the cloud you
    want to backup to when initializing.
  EOT
}

variable "backup_daemon_address" {
  type = string
  default = null
}

variable "k8s_namespaces" {
  type = list(string)
  description = "List of k8s namespaces that should be in the backup."
}

variable "bandwidth_limitation" {
  type = string
  description = "Bandwith limitation for ingress and egress. Prevent locking up the network through backups."
  default = "50M"
}

variable "cron_schedule" {
  type = string
  description = "How often the backup job should run"
  default = "0 4 * * *" # This runs the job every second day
}

variable "k0s_admin_user" {
  type = string
  description = "user to login to the host machine(s) with (needs passwordless sudo)."
  default = "admin"
}

variable "log_level" {
  type = string
  default = "INFO"
}
