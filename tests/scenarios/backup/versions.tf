terraform {
  backend "pg" {} # sourced entirely via .envrc

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.36.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "4.1.0"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "~>0.1.3" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}