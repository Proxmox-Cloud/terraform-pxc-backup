import logging
import os
import tempfile

import ansible_runner
import boto3
import dns.resolver
import paramiko
import pytest
import redis
import yaml
from kubernetes import client, config
from proxmoxer import ProxmoxAPI
from pve_cloud_test.cloud_fixtures import *
from pve_cloud_test.k8s_fixtures import *
from pve_cloud_test.tdd_watchdog import get_ipv4
from pve_cloud_test.terraform import apply, destroy

logger = logging.getLogger(__name__)


@cloud_fixture("lxc")
def create_backup_lxc(request, get_proxmoxer, get_test_env):
    logger.info("test create backup lxc")

    with tempfile.NamedTemporaryFile(
        "w", suffix=".yaml", delete=False
    ) as temp_dyn_lxcs_inv:
        yaml.dump(
            {
                "plugin": "pxc.cloud.lxc_inv",
                "target_pve": get_test_env["pve_test_cluster_name"]
                + "."
                + get_test_env["cloud_inventory"]["pve_cloud_domain"],
                "stack_name": "pytest-backup-lxc",
                "lxcs": [
                    {
                        "hostname": "main",
                        "parameters": {
                            "rootfs": f"volume={get_test_env["pve_vm_storage_id"]}:10",
                            "cores": 2,
                            "memory": 1024,
                            "net0": f"name=pve,bridge=vmbr0,firewall=1,ip=dhcp",
                            "mp0": f"volume={get_test_env["pve_vm_storage_id"]}:20,mp=/mnt/backup-drive",
                        },
                        "vars": {"PXC_BACKUP_BASE_DIR": "/mnt/backup-drive"},
                    }
                ],
                "lxc_global_vars": {"install_prom_systemd_exporter": True},
                "target_pve_hosts": list(get_test_env["pve_test_cluster_hosts"].keys()),
                "root_ssh_pub_key": get_test_env["ssh_pub_key"],
            },
            temp_dyn_lxcs_inv,
        )
        temp_dyn_lxcs_inv.flush()

        # we have to prefix the full path otherwise ansible-runner might ignore and use pxc collection from default path
        # this is a bug/error inside ansible-runner since it should honor the default ANSIBLE_COLLECTIONS_PATH env variable
        logger.info(f"collections path {os.getenv('ANSIBLE_COLLECTIONS_PATH')}")
        create_lxc_run = ansible_runner.run(
            project_dir=os.getcwd(),
            playbook=f"{os.getenv('ANSIBLE_COLLECTIONS_PATH')}/ansible_collections/pxc/cloud/playbooks/sync_lxcs.yaml",
            inventory=temp_dyn_lxcs_inv.name,
            verbosity=request.config.getoption("--ansible-verbosity"),
        )

        assert create_lxc_run.rc == 0

        # for local tdd with development watchdogs
        extra_vars = {}
        backup_vers, tdd_ip = get_tdd_version("pve-cloud-backup")

        if backup_vers:
            extra_vars["tdd_local_pypi_host"] = tdd_ip
            extra_vars["py_pve_cloud_backup_version"] = backup_vers

        setup_bdd_run = ansible_runner.run(
            project_dir=os.getcwd(),
            playbook=f"{os.getenv('ANSIBLE_COLLECTIONS_PATH')}/ansible_collections/pxc/cloud/playbooks/setup_backup_daemon.yaml",
            inventory=temp_dyn_lxcs_inv.name,
            verbosity=request.config.getoption("--ansible-verbosity"),
            extravars=extra_vars,
        )

        assert setup_bdd_run.rc == 0

        yield

        # always run the destroy
        destroy_lxcs_run = ansible_runner.run(
            project_dir=os.getcwd(),
            playbook=f"{os.getenv('ANSIBLE_COLLECTIONS_PATH')}/ansible_collections/pxc/cloud/playbooks/destroy_lxcs.yaml",
            inventory=temp_dyn_lxcs_inv.name,
            verbosity=request.config.getoption("--ansible-verbosity"),
        )
        assert destroy_lxcs_run.rc == 0


@cloud_fixture("scenario")
def backup_scenario(
    request, get_test_env, get_k8s_api_v1, get_kubespray_inv, create_backup_lxc
):
    scenario_name = "backup"

    extra_apply_env = {}

    backup_vers, tdd_ip = get_tdd_version("pve-cloud-backup")

    if backup_vers:
        extra_apply_env["TF_VAR_backup_image_base"] = f"{tdd_ip}:5000/pve-cloud-backup"
        extra_apply_env["TF_VAR_backup_image_version"] = backup_vers

    apply(
        "pxc-backup",
        scenario_name,
        get_k8s_api_v1,
        get_test_env,
        get_kubespray_inv,
        extra_apply_env,
    )  # this will wait till everything is running after apply

    yield

    destroy(
        "pxc-backup",
        scenario_name,
        get_k8s_api_v1,
        get_test_env,
        get_kubespray_inv,
        extra_apply_env,
    )
