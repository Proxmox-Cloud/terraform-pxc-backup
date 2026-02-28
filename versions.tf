terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.38.0"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "~>3.0.4" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}

