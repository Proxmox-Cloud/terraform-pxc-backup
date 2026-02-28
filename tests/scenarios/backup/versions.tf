terraform {
  backend "pg" {} # sourced entirely via .envrc

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.38.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "4.1.0"
    }
    helm = {
      source = "hashicorp/helm"
      version = "3.1.1"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "~>3.0.4" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}