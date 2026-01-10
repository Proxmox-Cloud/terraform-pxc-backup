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


@cloud_fixture("backup")
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
                + get_test_env["pve_test_cloud_domain"],
                "stack_name": "pytest-backup-lxc",
                "lxcs": [
                    {
                        "hostname": "main",
                        "parameters": {
                            "rootfs": f"volume={get_test_env["pve_test_disk_storage_id"]}:10",
                            "cores": 2,
                            "memory": 1024,
                            "net0": f"name=pve,bridge=vmbr0,firewall=1,ip=dhcp",
                            "mp0": f"volume={get_test_env["pve_test_disk_storage_id"]}:20,mp=/mnt/backup-drive",
                        },
                        "vars": {"PXC_BACKUP_BASE_DIR": "/mnt/backup-drive"},
                    }
                ],
                "lxc_global_vars": {"install_prom_systemd_exporter": True},
                "target_pve_hosts": list(get_test_env["pve_test_hosts"].keys()),
                "target_pve_hosts": list(get_test_env["pve_test_hosts"].keys()),
                "root_ssh_pub_key": get_test_env["pve_test_ssh_pub_key"],
            },
            temp_dyn_lxcs_inv,
        )
        temp_dyn_lxcs_inv.flush()

        create_lxc_run = ansible_runner.run(
            project_dir=os.getcwd(),
            playbook="pxc.cloud.sync_lxcs",
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
            playbook="pxc.cloud.setup_backup_daemon",
            inventory=temp_dyn_lxcs_inv.name,
            verbosity=request.config.getoption("--ansible-verbosity"),
            extravars=extra_vars,
        )

        assert setup_bdd_run.rc == 0

        yield

        if not request.config.getoption("--skip-cleanup"):
            # always run the destroy
            destroy_lxcs_run = ansible_runner.run(
                project_dir=os.getcwd(),
                playbook="playbooks/destroy_lxcs.yaml",
                inventory=temp_dyn_lxcs_inv.name,
                verbosity=request.config.getoption("--ansible-verbosity"),
            )
            assert destroy_lxcs_run.rc == 0


@pytest.fixture(scope="session")
def backup_scenario(request, set_pve_cloud_auth, get_k8s_api_v1, create_backup_lxc):
    scenario_name = "backup"

    backup_vers, tdd_ip = get_tdd_version("pve-cloud-backup")

    if backup_vers:
        os.environ["TF_VAR_backup_image_base"] = f"{tdd_ip}:5000/pve-cloud-backup"
        os.environ["TF_VAR_backup_image_version"] = backup_vers

    if not request.config.getoption("--skip-apply"):
        apply(
            "pxc-backup", scenario_name, get_k8s_api_v1, True, True
        )  # this will wait till everything is running after apply

    yield

    if not request.config.getoption("--skip-cleanup"):
        destroy(scenario_name)
