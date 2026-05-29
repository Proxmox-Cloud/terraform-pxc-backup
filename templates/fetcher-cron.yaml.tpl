# todo: this should be refactored into the proper terraform resources
# this is only in a template format to try to appease an ai agent that 
# is incapable of dealing with heredoc yamldecode in tf files ;DDD
apiVersion: batch/v1
kind: CronJob
metadata:
  name: fetcher-cron
  namespace: ${namespace}
spec:
  schedule: "${cron_schedule}"
  jobTemplate:
    spec:
      # limit 0 + restartPolicy: Never allows to see failed cron jobs logs
      # otherwise k8s will delete / try to recreate and error messages get lost
      backoffLimit: 0
      template:
        metadata:
          annotations:
            kubernetes.io/egress-bandwidth: ${bandwidth_limitation}
            kubernetes.io/ingress-bandwidth: ${bandwidth_limitation}
        spec:
          restartPolicy: Never
          volumes:
          - name: fetcher-config
            configMap:
              name: fetcher-config
          - name: ceph-config
            configMap:
              name: ceph-config
          - name: ceph-secrets
            secret:
              secretName: ceph-secrets
          - name: fetcher-secrets
            secret:
              secretName: fetcher-secrets
              defaultMode: 256
          - name: fetcher-tls-ca
            secret:
              secretName: fetcher-tls-ca

%{ if node_selector != null } 
          nodeSelector:
            ${indent(12, yamlencode(node_selector))}
%{ endif }
%{ if tolerations != null }
          tolerations:
            ${indent(12, yamlencode(tolerations))}
%{ endif }
          containers:
          - name: fetcher
            image: ${backup_image}:${backup_image_version}
            imagePullPolicy: Always
            args: ["fetcher"]
            env:
              - name: BDD_HOST
                value: "${backup_daemon_address}"
              - name: BDD_CA_CERT_PATH
                value: "/opt/bdd_ca.crt"
              - name: PROXMOXER_HOST
                value: "${pve_host}"
              - name: PROXMOXER_USER
                value: "root"
              - name: QEMU_ADMIN_USER
                value: "${qemu_admin_user}"
              - name: PATRONI_PASS
                valueFrom:
                  secretKeyRef:
                    name: fetcher-secrets
                    key: patroni-pass

%{ if nextcloud_url != null && nextcloud_user != null && nextcloud_pass != null }
              - name: NEXTCLOUD_USER
                value: "${nextcloud_user}"
              - name: NEXTCLOUD_BASE
                value: "${nextcloud_url}"
%{ endif }
            volumeMounts:
            - mountPath: /etc/ceph/ceph.conf
              name: ceph-config
              subPath: "ceph.conf"
            - mountPath: /opt/backup-conf.yaml
              name: fetcher-config
              subPath: "backup-conf.yaml"
            - mountPath: /etc/pve/priv/ceph.client.admin.keyring
              name: ceph-secrets
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
              
%{ if nextcloud_url != null && nextcloud_user != null && nextcloud_pass != null }
            - mountPath: /opt/nextcloud.pass
              name: fetcher-secrets
              subPath: nextcloud-pass
%{ endif }
%{ if git_repo_ssh_key != null && git_repo_ssh_key_type != null }
            - mountPath: /root/.ssh/id_${git_repo_ssh_key_type}
              name: fetcher-secrets
              subPath: id-git
%{ endif }
            - mountPath: /opt/bdd_ca.crt
              name: fetcher-tls-ca
              subPath: ca_cert.crt
