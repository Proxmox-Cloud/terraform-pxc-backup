import pytest
import yaml
from proxmoxer import ProxmoxAPI
import paramiko
import base64
import os
import re
import random
import string
from pve_cloud_test.terraform import apply, destroy
from kubernetes import client, config
import tempfile
import logging
import redis
from pve_cloud_test.cloud_fixtures import *
from pve_cloud_test.k8s_fixtures import *
from pve_cloud_test.tdd_watchdog import get_ipv4
import boto3
import dns.resolver
import time

logger = logging.getLogger(__name__)

@pytest.fixture(scope="session")
def backup_scenario(request, set_pve_cloud_auth, get_k8s_api_v1):
  scenario_name = "backup"

  if os.getenv("TDDOG_LOCAL_IFACE"):
    # get version for image from redis
    r = redis.Redis(host='localhost', port=6379, db=0)
    local_build_backup_version = r.get("version.pve-cloud-backup")

    if local_build_backup_version:
      logger.info(f"found local version {local_build_backup_version.decode()}")
      
      # set controller base image
      os.environ["TF_VAR_backup_image_base"] = f"{get_ipv4(os.getenv('TDDOG_LOCAL_IFACE'))}:5000/pve-cloud-backup"
      os.environ["TF_VAR_backup_image_version"] = local_build_backup_version.decode()
    else:
      logger.warning(f"did not find local build pve cloud build version even though TDDOG_LOCAL_IFACE is defined")

  if not request.config.getoption("--skip-apply"):
    apply("pxc-backup", scenario_name, get_k8s_api_v1, True, True) # this will wait till everything is running after apply

  yield 

  if not request.config.getoption("--skip-cleanup"):
    destroy(scenario_name)