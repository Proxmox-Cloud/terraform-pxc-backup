variable "namespace" {
  type = string
}

variable "storage_class_name" {
  type = string
}

resource "kubernetes_namespace" "namespace" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_persistent_volume_claim_v1" "busybox_pvc" {
  metadata {
    name = "busybox-pvc"
    namespace = kubernetes_namespace.namespace.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    storage_class_name = var.storage_class_name
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "busybox_pvc2" {
  metadata {
    name = "busybox-pvc2"
    namespace = kubernetes_namespace.namespace.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    storage_class_name = var.storage_class_name
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}
# simple running deployment
resource "kubernetes_deployment_v1" "busybox" {
  metadata {
    name = "busybox"
    namespace = kubernetes_namespace.namespace.metadata[0].name
    labels = {
      app = "busybox"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "busybox"
      }
    }

    template {
      metadata {
        labels = {
          app = "busybox"
        }
      }

      spec {
        container {
          name  = "busybox"
          image = "busybox:1.37"
          image_pull_policy = "IfNotPresent"

          # Keep the pod running forever
          command = ["/bin/sh", "-c", "while true; do sleep 3600; done"]

          volume_mount {
            name       = "data"
            mount_path = "/mnt/data"
          }
          volume_mount {
            name       = "data2"
            mount_path = "/mnt/data2"
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.busybox_pvc.metadata[0].name
          }
        }
        volume {
          name = "data2"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.busybox_pvc2.metadata[0].name
          }
        }
      }
    }
  }
}
