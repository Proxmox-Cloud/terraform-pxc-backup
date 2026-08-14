import logging
import os
import tempfile

import boto3
import dns.resolver
import paramiko
import pytest
import redis
import yaml
from kubernetes import client, config
from proxmoxer import ProxmoxAPI
from pve_cloud.lib.ssh import connect_host
from pve_cloud_test.cloud_fixtures import *
from pve_cloud_test.k8s_fixtures import *
from pve_cloud_test.tdd_watchdog import get_ipv4
from pve_cloud_test.terraform import apply, destroy

logger = logging.getLogger(__name__)


@cloud_fixture("qemu")
def create_backup_qemu(request, get_proxmoxer, get_test_env):
    logger.info("test create backup qemu")

    with tempfile.NamedTemporaryFile(
        "w", suffix=".yaml", delete=False
    ) as temp_dyn_lxcs_inv:
        yaml.dump(
            {
                "plugin": "pxc.cloud.qemu_inv",
                "target_pve": get_test_env["pve_test_cluster_name"]
                + "."
                + get_test_env["cloud_inventory"]["pve_cloud_domain"],
                "stack_name": "pytest-backup-qemu",
                "qemu_base_parameters": {
                    "cpu": "host",
                    "net0": "virtio,bridge=vmbr0,firewall=1"
                    + f"{get_test_env['net0_vlan_tag_rendered'] if 'net0_vlan_tag_rendered' in get_test_env else ''}",
                    "sockets": 1,
                },
                "qemus": [
                    {
                        "hostname": "main",
                        "disk": {
                            "size": "75G",
                            "options": {
                                "discard": "on",
                                "iothread": "on",
                                "ssd": "on",
                                "cache": "unsafe",
                            },
                            "pool": get_test_env["pve_vm_storage_id"],
                        },
                        "additional_disks": [
                            # disk for backup zfs
                            {
                                "from_storage": {
                                    "size": "50G",
                                    "options": {
                                        "discard": "on",
                                        "iothread": "on",
                                        "ssd": "on",
                                        "cache": "unsafe",
                                    },
                                    "pool": get_test_env["pve_vm_storage_id"],
                                }
                            },
                        ],
                        "vars": {
                            "zpool_backup_parameters": {
                                "pool_properties": {"ashift": "12"},  # only on ssds
                                "vdevs": [
                                    {
                                        "disks": [
                                            "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1"  # no pxzfs as custom
                                        ]
                                    },
                                ],
                            },
                            "bdd_log_level": "DEBUG",
                        },
                        "parameters": {
                            "cores": 2,
                            "memory": 4096,
                        },
                    },
                ],
                "target_pve_hosts": list(get_test_env["pve_test_cluster_hosts"].keys()),
                "root_ssh_pub_key": get_test_env["ssh_pub_key"],
            },
            temp_dyn_lxcs_inv,
        )
        temp_dyn_lxcs_inv.flush()

        extra_vars = {}
        backup_vers, tdd_ip = get_tdd_version("pve-cloud-backup")

        if backup_vers:
            extra_vars["tdd_local_pypi_host"] = tdd_ip
            extra_vars["py_pve_cloud_backup_version"] = backup_vers

        collections_path = os.getenv("ANSIBLE_COLLECTIONS_PATH")
        with run_playbook(
            request,
            temp_dyn_lxcs_inv.name,
            f"{collections_path}/ansible_collections/pxc/cloud/playbooks/sync_qemus.yaml",
            f"{collections_path}/ansible_collections/pxc/cloud/playbooks/setup_backup_daemon.yaml",
            destroy_playbook=f"{collections_path}/ansible_collections/pxc/cloud/playbooks/destroy_qemus.yaml",
            extra_vars=extra_vars,
        ):
            yield


@cloud_fixture("k0s", "k0s-edge")
def setup_k0s_bdd_server(request, get_test_env):
    k0s_inv, k0s_host = construct_k0s_ext_hosts_inv(get_test_env)
    # zfs backup ext test
    # requires k0s playbook first for zfs kernel modules
    with connect_host(k0s_host, user="admin") as ssh:
        _, stdout, _ = ssh.exec_command("sudo zpool list -H -o name")
        existing_pools = stdout.read().decode("utf-8").splitlines()
        logger.info(f"existing pools {existing_pools}")

        if "tank-ext" not in existing_pools:
            _, stdout, _ = ssh.exec_command(
                "sudo zpool create -o ashift=12 tank-ext /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2"
            )
            exit_status = stdout.channel.recv_exit_status()
            assert exit_status == 0

    extra_vars = {}
    backup_vers, tdd_ip = get_tdd_version("pve-cloud-backup")

    if backup_vers:
        extra_vars["tdd_local_pypi_host"] = tdd_ip
        extra_vars["py_pve_cloud_backup_version"] = backup_vers
        extra_vars["test_repos_ip"] = tdd_ip

    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as temp_k0s_inv:
        yaml.dump(
            {
                "plugin": "pxc.cloud.ext_hosts_inv",
                "pve_cloud_domain": get_test_env["cloud_inventory"]["pve_cloud_domain"],
                "target_cluster": get_test_env["pve_test_cluster_name"],
                "external_stack_name": "pytest-k0s",
                "typed_host_groups": {
                    "backup_daemon": {
                        "bdd_server": {
                            "ansible_user": "admin",
                            "ansible_host": k0s_host,
                            "use_existing_zpool": {"pool_name": "tank-ext"},
                            "bdd_log_level": "DEBUG",
                        }
                    }
                },
            },
            temp_k0s_inv,
        )
        temp_k0s_inv.flush()
        logger.info(f"ext hosts inv {temp_k0s_inv.name}")

        collections_path = os.getenv("ANSIBLE_COLLECTIONS_PATH")
        with run_playbook(
            request,
            temp_k0s_inv.name,
            f"{collections_path}/ansible_collections/pxc/cloud/playbooks/setup_backup_daemon.yaml",
            extra_vars=extra_vars,
        ):
            yield


@cloud_fixture("scenario")
def backup_scenario(
    request, get_test_env, get_k8s_api_v1, get_kubespray_inv, create_backup_qemu
):
    scenario_name = "backup"

    extra_apply_env = {}
    extra_apply_env["TF_VAR_e2e_kubespray_inv"] = get_kubespray_inv

    backup_vers, tdd_ip = get_tdd_version("pve-cloud-backup")

    if backup_vers:
        extra_apply_env["TF_VAR_backup_image_base"] = f"{tdd_ip}:5000/pve-cloud-backup"
        extra_apply_env["TF_VAR_backup_image_version"] = backup_vers

    apply(
        "pxc-backup",
        scenario_name,
        get_k8s_api_v1,
        get_test_env,
        extra_apply_env,
    )  # this will wait till everything is running after apply

    yield

    destroy("pxc-backup", scenario_name, get_test_env, extra_apply_env)


@cloud_fixture("secondary")
def secondary_scenario(
    request,
    backup_scenario,
    get_test_env,
    get_k8s_secondary_api_v1,
    get_secondary_kubespray_inv,
):
    scenario_name = "secondary"

    extra_apply_env = {}
    extra_apply_env["TF_VAR_e2e_kubespray_inv"] = get_secondary_kubespray_inv

    backup_vers, tdd_ip = get_tdd_version("pve-cloud-backup")

    if backup_vers:
        extra_apply_env["TF_VAR_backup_image_base"] = f"{tdd_ip}:5000/pve-cloud-backup"
        extra_apply_env["TF_VAR_backup_image_version"] = backup_vers

    apply(
        "pxc-backup",
        scenario_name,
        get_k8s_secondary_api_v1,
        get_test_env,
        extra_apply_env,
    )  # this will wait till everything is running after apply

    yield

    destroy(
        "pxc-backup",
        scenario_name,
        get_test_env,
        extra_apply_env,
    )


@cloud_fixture("k0s-edge", "k0s", "k0s-tf", "k0s-tf")
def k0s_edge_scenario(
    request, setup_k0s_bdd_server, secondary_scenario, get_test_env, get_k0s_api_v1
):
    scenario_name = "k0s-edge"

    extra_apply_env = {}
    k0s_inv, _ = construct_k0s_ext_hosts_inv(get_test_env)
    extra_apply_env["TF_VAR_e2e_k0s_ext_hosts_inv"] = k0s_inv

    backup_vers, tdd_ip = get_tdd_version("pve-cloud-backup")

    if backup_vers:
        extra_apply_env["TF_VAR_backup_image_base"] = f"{tdd_ip}:5000/pve-cloud-backup"
        extra_apply_env["TF_VAR_backup_image_version"] = backup_vers

    apply(
        "pxc-backup",
        scenario_name,
        get_k0s_api_v1,
        get_test_env,
        extra_apply_env,
    )  # this will wait till everything is running after apply

    yield

    destroy(
        "pxc-backup",
        scenario_name,
        get_test_env,
        extra_apply_env,
    )
