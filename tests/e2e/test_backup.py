import asyncio
import logging
import pickle
import random
import string
import struct
import time

import dns.query
import dns.tsigkeyring
import dns.zone
import pytest
import requests
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.x509.oid import NameOID
from fixtures import *
from kubernetes import client
from kubernetes.client import V1Job, V1JobSpec, V1ObjectMeta
from kubernetes.client.rest import ApiException
from kubernetes.stream import stream
from pve_cloud_backup.daemon.brctl import get_parser, launch_restore_job
from pve_cloud_backup.daemon.rpc import Command

logger = logging.getLogger(__name__)


def random_string(length=16):
    return "".join(random.choices(string.ascii_letters + string.digits, k=length))


@pytest.mark.asyncio
async def test_backup(get_test_env, get_proxmoxer, set_k8s_auth, backup_scenario):
    logger.info("test backup create and restore")

    kubeconfig = set_k8s_auth

    # auth kubernetes api
    with tempfile.NamedTemporaryFile(mode="w", delete=False) as temp_file:
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
        command=["sh", "-c", f"echo '{content}' > {filename}"],
        stderr=True,
        stdin=False,
        stdout=True,
        tty=False,
    )

    # trigger the backup cron and monitor
    cronjob_name = "fetcher-cron"
    cj = v1_batch.read_namespaced_cron_job(
        name=cronjob_name, namespace="pve-cloud-backup"
    )
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
        time.sleep(5)  # give pods some time to create / dont spam api

        # fetch the pod and wait for it to finish
        pods = v1.list_namespaced_pod(
            namespace="pve-cloud-backup", label_selector=f"job-name={job_name}"
        ).items

        assert pods

        pod = pods[0]

        phase = pod.status.phase

        assert (
            phase != "Failed"
        ), f"pod {pod.metadata.name} failed!"  # failed pods end tests immediatly

        if phase == "Succeeded":
            break  # finished

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
    resolver.nameservers = [get_test_env["pve_test_cloud_inv"]["bind_master_ip"]]

    ddns_answer = resolver.resolve(
        f"{backup_lxc['name']}.{get_test_env['pve_test_cloud_domain']}"
    )
    ddns_ips = [rdata.to_text() for rdata in ddns_answer]
    logger.info(ddns_ips)
    assert ddns_ips  # assert ddns response

    time.sleep(10)  # wait for borg repo lock to be released

    # call brctl methods
    reader, writer = await asyncio.open_connection(ddns_ips[0], 8085)
    writer.write(struct.pack("B", Command.LIST_BACKUPS.value))
    await writer.drain()

    # read the response archives size and then the archives
    dict_size = struct.unpack("!I", (await reader.readexactly(4)))[0]
    archives = pickle.loads((await reader.readexactly(dict_size)))

    # fetch local backup image version if build via tdd
    backup_vers, tdd_ip = get_tdd_version("pve-cloud-backup")

    image = None
    if backup_vers:
        image = f"{tdd_ip}:5000/pve-cloud-backup:{backup_vers}"

    latest_timestamp = sorted(archives)[-1]
    logger.info(latest_timestamp)

    brctl_parser = get_parser()

    restore_args = brctl_parser.parse_args(
        [
            "restore-k8s",
            "--bdd-host",
            ddns_ips[0],
            "--target-pve",
            f"{get_test_env['pve_test_cluster_name']}.{get_test_env['pve_test_cloud_domain']}",
            "--stack-name",
            "pytest-k8s",
            "--image",
            image,
            "--timestamp",
            latest_timestamp,
            "--namespace-mapping",
            "test-backup-source:test-backup-restore",
            "--auto-scale",
            "--auto-delete",
        ]
    )

    launch_restore_job(restore_args)

    # wait for the restore job to finish
    while True:
        time.sleep(5)  # give pods some time to create / dont spam api

        # fetch the pod and wait for it to finish
        pods = v1.list_namespaced_pod(
            namespace="pve-cloud-backup",
            label_selector=f"job=pxc-restore-{latest_timestamp}",
        ).items

        assert pods

        pod = pods[0]

        phase = pod.status.phase

        assert (
            phase != "Failed"
        ), f"pod {pod.metadata.name} failed!"  # failed pods end tests immediatly

        if phase == "Succeeded":
            break  # finished

        logger.info(f"pod {pod.metadata.name} in phase {phase}")

    # wait for the pod to be running again and exec into it when it is
    while True:
        pods = v1.list_namespaced_pod(
            namespace="test-backup-restore", label_selector=f"app=busybox"
        ).items

        assert pods

        pod = pods[0]

        phase = pod.status.phase

        assert (
            phase != "Failed"
        ), f"pod {pod.metadata.name} failed!"  # failed pods end tests immediatly

        if phase == "Running":
            time.sleep(5)  # give some small time buffer to init fully
            break  # ready for exec

    resp = stream(
        v1.connect_get_namespaced_pod_exec,
        pod.metadata.name,
        "test-backup-restore",
        command=["cat", filename],
        stderr=True,
        stdin=False,
        stdout=True,
        tty=False,
    )

    logger.info(resp)

    assert resp.strip() == content
