resource "kubernetes_namespace" "backup" {
  metadata {
    name = "pve-cloud-backup"
  }
}

data "pxc_ceph_access" "ceph_access" {}

data "pxc_ssh_key" "host_rsa" {
  key_type = "PVE_HOST_RSA"
}

data "pxc_ssh_key" "automation" {
  key_type = "AUTOMATION"
}

data "pxc_cloud_secret" "patroni" {
  secret_name = "patroni.pass"
}

data "pxc_pve_host" "host" {
}


# create config map for the backupper
resource "kubernetes_config_map" "fetcher_config" {
  metadata {
    name = "fetcher-config"
    namespace = kubernetes_namespace.backup.metadata[0].name
  }

  data = {
    "ceph.conf" = data.pxc_ceph_access.ceph_access.ceph_conf
    "backup-conf.yaml" = yamlencode(var.backup_config)
  }
}

resource "kubernetes_secret" "fetcher_secrets" {
  metadata {
    name = "fetcher-secrets"
    namespace = kubernetes_namespace.backup.metadata[0].name
  }
  data = merge({
    "pve-id-rsa" = data.pxc_ssh_key.host_rsa.key
    "ceph-admin-keyring" = data.pxc_ceph_access.ceph_access.admin_keyring
    "qemu-id"= data.pxc_ssh_key.automation.key
    "patroni-pass" = data.pxc_cloud_secret.patroni.secret
  },
  var.nextcloud_pass != null ? {
    "nextcloud-pass" = var.nextcloud_pass
  }: {},
  var.git_repo_ssh_key != null && var.git_repo_ssh_key_type != null ? {
    "id-git" = var.git_repo_ssh_key
  } : {}
  )
}

# cluster admin access for backup tool 
# todo: restrict access to read only and what the fetcher actually needs
resource "kubernetes_cluster_role_binding" "default_fetcher_sa_admin" {
  metadata {
    name = "pve-cloud-backup-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace.backup.metadata[0].name
  }
}


resource "kubernetes_manifest" "fetcher_cron" {
  manifest = yamldecode(<<-YML
    apiVersion: batch/v1
    kind: CronJob
    metadata:
      name: fetcher-cron
      namespace: ${kubernetes_namespace.backup.metadata[0].name}
    spec:
      schedule: "${var.cron_schedule}"
      jobTemplate:
        spec:
          backoffLimit: 0
          template:
            metadata:
              annotations:
                # limit the bandwidth to not crash ceph
                kubernetes.io/egress-bandwidth: ${var.bandwidth_limitation}
                kubernetes.io/ingress-bandwidth: ${var.bandwidth_limitation}
            spec:
              containers:
              - name: fetcher
                image: ${local.backup_image_base}:${local.backup_image_version}
                imagePullPolicy: Always
                command: [ "fetcher" ]
                env:
                  - name: PROXMOXER_HOST
                    value: "${data.pxc_pve_host.host.pve_host}"
                  - name: PROXMOXER_USER
                    value: 'root'
                  - name: QEMU_ADMIN_USER
                    value: '${var.qemu_admin_user}'
                  - name: PATRONI_PASS
                    valueFrom:
                      secretKeyRef:
                        name: fetcher-secrets
                        key: patroni-pass
      %{ if var.nextcloud_url != null && var.nextcloud_user != null && var.nextcloud_pass != null }
                  - name: NEXTCLOUD_USER
                    value: '${var.nextcloud_user}'
                  - name: NEXTCLOUD_BASE
                    value: '${var.nextcloud_url}'
      %{ endif }
                volumeMounts:
                - mountPath: /etc/ceph/ceph.conf
                  name: fetcher-config
                  subPath: "ceph.conf"
                - mountPath: /opt/backup-conf.yaml
                  name: fetcher-config
                  subPath: "backup-conf.yaml"
                - mountPath: /etc/pve/priv/ceph.client.admin.keyring
                  name: fetcher-secrets
                  subPath: "ceph-admin-keyring"
                - mountPath: /root/.ssh/id_rsa
                  name: fetcher-secrets
                  subPath: "pve-id-rsa"
                - mountPath: /opt/id_proxmox
                  name: fetcher-secrets
                  subPath: "pve-id-rsa"
                - mountPath: /opt/id_qemu
                  name: fetcher-secrets
                  subPath: "qemu-id"
      %{ if var.nextcloud_url != null && var.nextcloud_user != null && var.nextcloud_pass != null }
                - mountPath: /opt/nextcloud.pass
                  name: fetcher-secrets
                  subPath: nextcloud-pass
      %{ endif }
      %{ if var.git_repo_ssh_key != null && var.git_repo_ssh_key_type != null }
                - mountPath: /root/.ssh/id_${var.git_repo_ssh_key_type}
                  name: fetcher-secrets
                  subPath: id-git
      %{ endif }
              restartPolicy: Never # see logs of failed containers
              volumes:
              - name: fetcher-config
                configMap:
                  name: fetcher-config
              - name: fetcher-secrets
                secret:
                  secretName: fetcher-secrets
                  defaultMode: 256 # ssh key permissions
  YML
  )
}

