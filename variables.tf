# we need to do these shenanigans because we cannot pass variables conditionally to this module during tdd
locals {
  backup_image_base = var.backup_image_base == null ? "tobiashvmz/pve-cloud-backup" : var.backup_image_base
  backup_image_version = var.backup_image_version == null ? "3.5.8" : var.backup_image_version
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

variable "backup_daemon_address" {
  type = string
  description = <<-EOT
    Address for the backup server (optional). When omitted will use the address from the backup discovery secret. Set this
    to https://your-multicloud-gateway.domain + set the variable mc_ext_token to send backups to another cloud.
  EOT
  default = null
}

variable "mc_ext_token" {
  type = string
  description = <<-EOT
    If you set the backup daemon address to https:// it will assume you want to backup via the multi cloud gateway. Set
    this variable to the external token (from external-mc-token discovery secret).
  EOT
  default = null
}

variable "enable_ceph_csi_backups" {
  type = bool
  description = "Whether or not to fetch the ceph config / access of the proxmox cluster. This enables ceph csi backups, defaults to true."
  default = true
}

variable "patroni_stack" {
  type = string
  description = "Stack fqdn of the patroni lxcs for backing up postgres dumps."
  default = null
}

variable "k8s_namespaces" {
  type = list(string)
  description = "List of k8s namespaces that should be in the backup."
}

variable "git_repo_ssh_key" {
  type = string
  description = "SSH private key for backing up git repos."
  default = null
}

variable "git_repo_ssh_key_type" {
  type = string
  description = "SSH private key type. Needs to be specified for ssh to autoload via ~/.ssh/id_..."
  default = "ed25519"
  validation {
    condition     = contains(["rsa", "ed25519", "ecdsa", "dsa"], var.git_repo_ssh_key_type)
    error_message = "The SSH key type must be one of: rsa, ed25519, ecdsa, dsa."
  }
}

variable "git_repos" {
  type = list(string)
  description = "Git repositories that should be backupped. Requires the git ssh key to be set."
  default = null
}

variable "nextcloud_url" {
  type = string
  description = "URL of Nextcloud instance we want to backup files from"
  default = null
}

variable "nextcloud_pass" {
  type = string
  description = "Nextcloud password for accessing files."
  default = null
}

variable "nextcloud_user" {
  type = string
  description = "Nextcloud user login name."
  default = null
}

variable "nextcloud_files" {
  type = list(string)
  description = "Nextcloud files to backup. Requires url, user and pass to be set."
  default = null
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

variable "qemu_admin_user" {
  type = string
  description = "user to login to pve cloud vms with"
  default = "admin"
}

variable "node_selector" {
  type = map(string)
  default = null
  description = "Optional node selector for controller deployments/jobs."
}

variable "tolerations" {
  type = list(map(string))
  default = null
  description = "Tolerations to add to all controller deployments/jobs."
}

variable "log_level" {
  type = string
  default = "INFO"
}
