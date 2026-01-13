terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.38.0"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "~>0.1.5" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}

