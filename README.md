# Proxmox Cloud Backup Module

Installs the proxmox cloud backup cron job deployment on K8S. 

This part is responsible for collecting backups and sending them to the proxmox cloud backup server.

### Backup

The [backup module](https://registry.terraform.io/modules/Proxmox-Cloud/backup/pxc/latest) installs a cron job inside k8s that uses ceph csi volume snapshots and rbd volume groups, to provide atomic backups of an entire k8s namespace.

It also equips a cluster with secrets so that we can start restore jobs using `brctl` from [pve-cloud-backup](github.com/Proxmox-Cloud/pve-cloud-backup).