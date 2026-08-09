import asyncio
import logging
import pickle
import random
import ssl
import string
import struct
import time

import dns.query
import dns.tsigkeyring
import dns.zone
import pytest
import requests
import yaml
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.x509.oid import NameOID
from fixtures import *
from kubernetes import client
from kubernetes.client import V1Job, V1JobSpec, V1ObjectMeta
from kubernetes.client.rest import ApiException
from kubernetes.stream import stream
from pve_cloud_backup.daemon.brctl import (get_parser, launch_restore_job,
                                           list_backup_details_remote)
from pve_cloud_backup.daemon.rpc import Command
from pve_cloud_test.cloud_fixtures import *
from pve_cloud_test.k8s_fixtures import construct_k0s_ext_hosts_inv

logger = logging.getLogger(__name__)


def random_string(length=16):
    return "".join(random.choices(string.ascii_letters + string.digits, k=length))


@pytest.mark.asyncio
async def test_create_qemu(get_test_env, create_backup_qemu):
    logger.info("test create backup qemu")


@pytest.mark.asyncio
async def test_setup_k0s_bdd(get_test_env, setup_k0s_bdd_server):
    logger.info("test k0s bdd setup")


def create_random_content(v1):
    pods = v1.list_namespaced_pod(namespace="test-backup-source")

    assert pods.items

    pod_name = pods.items[0].metadata.name

    filename = f"/mnt/data/{random_string(12)}.txt"
    content = random_string(32)

    logger.info(f"filename {filename}, content {content}")

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

    # give ceph some time to write out before starting backup job that will snapshot
    time.sleep(10)

    return content, filename  # written content


def trigger_fetch_job(v1, v1_batch):
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


async def validate_backups_created(get_test_env, get_proxmoxer, bdd_host_ip=None):
    ddns_ips = None # hacky
    if bdd_host_ip is None:
        backup_qemu = None
        for node in get_proxmoxer.nodes.get():
            for qemu in get_proxmoxer.nodes(node["node"]).qemu.get():
                if "main-pytest-backup-qemu" in qemu["name"]:
                    backup_qemu = qemu

        assert backup_qemu

        logger.info(backup_qemu)

        resolver = dns.resolver.Resolver()
        resolver.nameservers = [get_test_env["cloud_inventory"]["bind_master_ip"]]

        ddns_answer = resolver.resolve(
            f"{backup_qemu['name']}.{get_test_env['cloud_inventory']['pve_cloud_domain']}"
        )
        ddns_ips = [rdata.to_text() for rdata in ddns_answer]
        logger.info(ddns_ips)
        assert ddns_ips  # assert ddns response

        bdd_host_ip = ddns_ips[0]

    time.sleep(10)  # wait for borg repo lock to be released

    # call brctl methods
    ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE
    reader, writer = await asyncio.open_connection(bdd_host_ip, 8085, ssl=ssl_ctx)
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

    # list details debug
    await list_backup_details_remote(
        brctl_parser.parse_args(
            [
                "backup-details",
                "--bdd-host",
                bdd_host_ip,
                "--timestamp",
                latest_timestamp,
            ]
        )
    )

    return ddns_ips, image, latest_timestamp


async def validate_restore_job(latest_timestamp, v1, filename, created_content, namespace="test-backup-restore"):
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
            namespace=namespace, label_selector=f"app=busybox"
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
        namespace,
        command=["cat", filename],
        stderr=True,
        stdin=False,
        stdout=True,
        tty=False,
    )

    logger.info(resp)

    assert resp.strip() == created_content


@pytest.mark.asyncio
async def test_backup(
    get_test_env,
    get_proxmoxer,
    get_k8s_api_v1,
    get_k8s_api_v1_batch,
    backup_scenario,
    get_kubespray_inv,
):
    logger.info("test backup create and restore")

    # create random file with random content in test pod
    created_content, filename = create_random_content(get_k8s_api_v1)

    # trigger the backup cron and monitor
    trigger_fetch_job(get_k8s_api_v1, get_k8s_api_v1_batch)

    # find the backup lxc, get its ip and paramiko into it to test the if the backup was created
    ddns_ips, image, latest_timestamp = await validate_backups_created(
        get_test_env, get_proxmoxer
    )

    brctl_parser = get_parser()

    restore_args = brctl_parser.parse_args(
        [
            "restore-k8s",
            "--bdd-host",
            ddns_ips[0],
            "--inventory",
            get_kubespray_inv,
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

    await launch_restore_job(restore_args)

    await validate_restore_job(
        latest_timestamp, get_k8s_api_v1, filename, created_content
    )


@pytest.mark.asyncio
async def test_secondary_backup(
    get_test_env,
    get_proxmoxer,
    secondary_scenario,
    get_k8s_secondary_api_v1,
    get_k8s_secondary_api_v1_batch,
    get_secondary_kubespray_inv,
):
    logger.info("testing openebs localpv zfs zpool secondary backup")

    # create random file with random content in test pod
    created_content, filename = create_random_content(get_k8s_secondary_api_v1)

    # trigger the backup cron and monitor
    trigger_fetch_job(get_k8s_secondary_api_v1, get_k8s_secondary_api_v1_batch)

    ddns_ips, image, latest_timestamp = await validate_backups_created(
        get_test_env, get_proxmoxer
    )

    brctl_parser = get_parser()

    restore_args = brctl_parser.parse_args(
        [
            "restore-k8s",
            "--bdd-host",
            ddns_ips[0],
            "--inventory",
            get_secondary_kubespray_inv,
            "--image",
            image,
            "--timestamp",
            latest_timestamp,
            "--namespace-mapping",
            "test-backup-source:test-backup-restore",
            "--auto-scale",
            "--auto-delete",
            "--log-level",
            "DEBUG",
        ]
    )

    await launch_restore_job(restore_args)

    await validate_restore_job(
        latest_timestamp, get_k8s_secondary_api_v1, filename, created_content
    )


@pytest.mark.asyncio
async def test_restore_zfs_ceph(
    get_test_env,
    get_proxmoxer,
    backup_scenario,
    secondary_scenario,
    get_k8s_api_v1,
    get_k8s_api_v1_batch,
    get_kubespray_inv,
    get_k8s_secondary_api_v1,
    get_k8s_secondary_api_v1_batch,
    get_secondary_kubespray_inv,
):
    logger.info("testing restore from zfs csi to ceph csi")

    created_content, filename = create_random_content(get_k8s_secondary_api_v1)

    # trigger the backup cron and monitor
    trigger_fetch_job(get_k8s_secondary_api_v1, get_k8s_secondary_api_v1_batch)

    ddns_ips, image, latest_timestamp = await validate_backups_created(
        get_test_env, get_proxmoxer
    )

    brctl_parser = get_parser()

    restore_args = brctl_parser.parse_args(
        [
            "restore-k8s",
            "--bdd-host",
            ddns_ips[0],
            "--inventory",
            get_kubespray_inv,
            "--image",
            image,
            "--timestamp",
            latest_timestamp,
            "--namespace-mapping",
            "test-backup-source:test-backup-restore-zfs",
            "--auto-scale",
            "--auto-delete",
            "--log-level",
            "DEBUG",
            "--sc-mapping",
            f"openebs-zfspv-zvol:csi-rbd-sc-{get_test_env['ceph_csi_storage_pool']}",  # todo: ceph pool needs to be fetched from get_test_env
        ]
    )

    await launch_restore_job(restore_args)

    await validate_restore_job(
        latest_timestamp, get_k8s_api_v1, filename, created_content, namespace="test-backup-restore-zfs"
    )


@pytest.mark.asyncio
async def test_restore_ceph_zfs(
    get_test_env,
    get_proxmoxer,
    backup_scenario,
    secondary_scenario,
    get_k8s_api_v1,
    get_k8s_api_v1_batch,
    get_kubespray_inv,
    get_k8s_secondary_api_v1,
    get_k8s_secondary_api_v1_batch,
    get_secondary_kubespray_inv,
):
    logger.info("testing restore from ceph csi to zfs csi")

    created_content, filename = create_random_content(get_k8s_api_v1)

    # trigger the backup cron and monitor
    trigger_fetch_job(get_k8s_api_v1, get_k8s_api_v1_batch)

    ddns_ips, image, latest_timestamp = await validate_backups_created(
        get_test_env, get_proxmoxer
    )

    brctl_parser = get_parser()

    restore_args = brctl_parser.parse_args(
        [
            "restore-k8s",
            "--bdd-host",
            ddns_ips[0],
            "--inventory",
            get_secondary_kubespray_inv,
            "--image",
            image,
            "--timestamp",
            latest_timestamp,
            "--namespace-mapping",
            "test-backup-source:test-backup-restore-ceph",
            "--auto-scale",
            "--auto-delete",
            "--log-level",
            "DEBUG",
            "--sc-mapping",
            f"csi-rbd-sc-{get_test_env['ceph_csi_storage_pool']}:openebs-zfspv-zvol",  # todo: ceph pool needs to be fetched from get_test_env
        ]
    )

    await launch_restore_job(restore_args)

    await validate_restore_job(
        latest_timestamp, get_k8s_secondary_api_v1, filename, created_content, namespace="test-backup-restore-ceph"
    )


@pytest.mark.asyncio
async def test_restore_k0s(
    get_test_env,
    get_proxmoxer,
    k0s_edge_scenario,
    get_k0s_api_v1,
    get_k0s_api_v1_batch
):
    logger.info("testing restore within remote k0s node")

    k0s_inv, k0s_host = construct_k0s_ext_hosts_inv(get_test_env)

    created_content, filename = create_random_content(get_k0s_api_v1)

    # trigger the backup cron and monitor
    trigger_fetch_job(get_k0s_api_v1, get_k0s_api_v1_batch)

    _, image, latest_timestamp = await validate_backups_created(
        get_test_env, get_proxmoxer, bdd_host_ip=k0s_host
    )

    brctl_parser = get_parser()

    restore_args = brctl_parser.parse_args(
        [
            "restore-k8s",
            "--bdd-host",
            k0s_host, # k0s node is simultaneously the backup host for e2e
            "--inventory",
            k0s_inv,
            "--image",
            image,
            "--timestamp",
            latest_timestamp,
            "--namespace-mapping",
            "test-backup-source:test-backup-restore",
            "--auto-scale",
            "--auto-delete",
            "--log-level",
            "DEBUG"
        ]
    )

    await launch_restore_job(restore_args)

    await validate_restore_job(
        latest_timestamp, get_k0s_api_v1, filename, created_content
    )


@pytest.mark.asyncio
async def test_restore_ceph_k0s(
    get_test_env,
    get_proxmoxer,
    k0s_edge_scenario,
    get_k0s_api_v1,
    get_k0s_api_v1_batch,
    backup_scenario,
    get_k8s_api_v1,
    get_k8s_api_v1_batch,
    get_kubespray_inv,

):
    logger.info("testing restore from main ceph kubespray to remote k0s node")

    k0s_inv, k0s_host = construct_k0s_ext_hosts_inv(get_test_env)

    created_content, filename = create_random_content(get_k8s_api_v1)

    # trigger the backup cron and monitor
    trigger_fetch_job(get_k8s_api_v1, get_k8s_api_v1_batch)

    # backup to main bdd as per default job definition
    ddns_ips, image, latest_timestamp = await validate_backups_created(
        get_test_env, get_proxmoxer
    )

    brctl_parser = get_parser()

    restore_args = brctl_parser.parse_args(
        [
            "restore-k8s",
            "--bdd-host",
            ddns_ips[0],
            "--inventory",
            k0s_inv,
            "--image",
            image,
            "--timestamp",
            latest_timestamp,
            "--namespace-mapping",
            "test-backup-source:test-backup-restore-ceph",
            "--auto-scale",
            "--auto-delete",
            "--log-level",
            "DEBUG",
            "--sc-mapping",
            f"csi-rbd-sc-{get_test_env['ceph_csi_storage_pool']}:openebs-zfspv-zvol",
        ]
    )

    await launch_restore_job(restore_args)

    await validate_restore_job(
        latest_timestamp, get_k0s_api_v1, filename, created_content, namespace="test-backup-restore-ceph"
    )
