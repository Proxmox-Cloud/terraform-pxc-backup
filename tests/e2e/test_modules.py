
from scenarios import *
import ssl
import socket
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.x509.oid import NameOID
import time
from kubernetes import client
import dns.query
import dns.tsigkeyring
import dns.zone
import logging
import requests
import pprint
import random
import string
from kubernetes.stream import stream
from kubernetes.client import V1ObjectMeta, V1Job, V1JobSpec
import json
import requests
from kubernetes.client.rest import ApiException
import pytest


logger = logging.getLogger(__name__)


def random_string(length=16):
    return ''.join(random.choices(string.ascii_letters + string.digits, k=length))


def test_backup(get_test_env, get_proxmoxer, set_k8s_auth, backup_scenario):
  logger.info("test backup create and restore")

  kubeconfig = set_k8s_auth

  # auth kubernetes api
  with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp_file:
    temp_file.write(kubeconfig)
    temp_file.flush()
    config.load_kube_config(config_file=temp_file.name)

  v1 = client.CoreV1Api()
  v1_batch = client.BatchV1Api()

  # create random file with random content in test pod
  pods = v1.list_namespaced_pod(namespace="test-backup-source")

  assert pods.items

  pod_name = pods.items[0].metadata.name
  
  filename = f"/mnt/data/{random_string(12)}.txt"
  content = random_string(32)

  resp = stream(
    v1.connect_get_namespaced_pod_exec,
    pod_name,
    "test-backup-source",
    command=[
      "sh",
      "-c",
      f"echo '{content}' > {filename}"
    ],
    stderr=True,
    stdin=False,
    stdout=True,
    tty=False
  )

  # trigger the backup cron and monitor
  cronjob_name = "fetcher-cron"
  cj = v1_batch.read_namespaced_cron_job(name=cronjob_name, namespace="pve-cloud-backup")
  tmpl = cj.spec.job_template
  job_name = f"{cronjob_name}-manual-{int(time.time())}"

  print(f"launching {job_name}")

  job = V1Job(
      metadata=V1ObjectMeta(name=job_name),
      spec=V1JobSpec(
          template=tmpl.spec.template,
          backoff_limit=tmpl.spec.backoff_limit,
      ),
  )

  job = v1_batch.create_namespaced_job(namespace="pve-cloud-backup", body=job)

  while True:
    time.sleep(5) # give pods some time to create / dont spam api

    # fetch the pod and wait for it to finish
    pods = v1.list_namespaced_pod(
      namespace="pve-cloud-backup",
      label_selector=f"job-name={job_name}"
    ).items

    assert pods

    pod = pods[0]

    phase = pod.status.phase

    assert phase != "Failed", f"pod {pod.metadata.name} failed!" # failed pods end tests immediatly

    if phase == "Succeeded":
      break # finished

    logger.info(f"pod {pod.metadata.name} in phase {phase}")

  # find the backup lxc, get its ip and paramiko into it to test the if the backup was created
  backup_lxc = None
  for node in get_proxmoxer.nodes.get():
    for lxc in get_proxmoxer.nodes(node["node"]).lxc.get():
      if "main-pytest-backup-lxc" in lxc["name"]:
        backup_lxc = lxc

  assert backup_lxc

  logger.info(backup_lxc)

  resolver = dns.resolver.Resolver()
  resolver.nameservers = [get_test_env['pve_test_cloud_inv']['bind_master_ip']]

  ddns_answer = resolver.resolve(f"{backup_lxc['name']}.{get_test_env['pve_test_cloud_domain']}")
  ddns_ips = [rdata.to_text() for rdata in ddns_answer]
  logger.info(ddns_ips)
  assert ddns_ips # assert ddns response

  time.sleep(10) # wait for borg repo lock to be released

  ssh = paramiko.SSHClient()
  ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
  ssh.connect(ddns_ips[0], username="root")

  _, stdout, stderr = ssh.exec_command("/opt/bdd/.venv/bin/brctl list-backups --json --backup-path /mnt/backup-drive")

  backup_timestamps = json.loads(stdout.read().decode('utf-8')) # sorted

  assert backup_timestamps, f"no output on list-backups {stderr.read().decode('utf-8')}"

  logger.info(backup_timestamps)

  latest_backup_timestamp = backup_timestamps[-1]

  # write kubeconfig via b64 decode to the lxc
  _, stdout, _ = ssh.exec_command(f"echo {base64.b64encode(kubeconfig.encode('utf-8')).decode('utf-8')} | base64 -d > /root/pytest-kubeconfig.yml")

  # restore the backup
  full_restore_command = (f"/opt/bdd/.venv/bin/brctl restore-k8s --backup-path /mnt/backup-drive --timestamp {latest_backup_timestamp} " + 
    f"--k8s-stack-name pytest-k8s.{get_test_env['pve_test_cloud_domain']} --namespace-mapping test-backup-source:test-backup-restore " +
    "--auto-scale --auto-delete")
  
  logger.info(full_restore_command)
  _, stdout, stderr = ssh.exec_command(full_restore_command)

  exit_status = stdout.channel.recv_exit_status()
  assert exit_status == 0

  # wait for the pod to be running again and exec into it when it is
  while True:
    pods = v1.list_namespaced_pod(
      namespace="test-backup-restore",
      label_selector=f"app=busybox"
    ).items

    assert pods

    pod = pods[0]

    phase = pod.status.phase

    assert phase != "Failed", f"pod {pod.metadata.name} failed!" # failed pods end tests immediatly

    if phase == "Running":
      time.sleep(5) # give some small time buffer to init fully
      break # ready for exec

  resp = stream(
    v1.connect_get_namespaced_pod_exec,
    pod.metadata.name,
    "test-backup-restore",
    command=[
      "cat", filename
    ],
    stderr=True,
    stdin=False,
    stdout=True,
    tty=False
  )

  logger.info(resp)

  assert resp.strip() == content