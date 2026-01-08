terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.36.0"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "0.1.3-rc2" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}

