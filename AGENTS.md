# terraform-pxc-backup

## Main module (repo root)

Deploys the backup stack into a Proxmox Cloud k8s cluster: `fetcher-cron` cron job (ceph csi volume snapshots → borg archives on the BDD), `fetcher-config`/`fetcher-secrets`/`fetcher-tls-ca` config, and the secrets needed to launch `brctl restore-k8s` jobs. Backups are sent directly to the BDD (via TLS discovery secret) or proxied through the multi-cloud gateway (`backup_daemon_address` + `mc_ext_token`).

## Submodules (`modules/`)

- **access-namespace** — Standalone access/restore setup for a namespace only (no cron job), for clusters that just need to restore from an existing `pve-cloud-backup` server via `brctl`.
- **k0s-edge-zfs-localpv** — Stripped-down variant for external non-PXC k0s edge systems with zfs csi underneath; configures backup cron + restores funneling to any BDD (`use_mc_gw_as_host`).

## Testing (E2E)

`tests/e2e/fixtures.py` defines session-scoped **cloud fixtures** (`@cloud_fixture(*tags)` from `pve_cloud_test.cloud_fixtures`). Fixtures either run `pxc/cloud` ansible playbooks (via `run_playbook`) or `terraform apply` a scenario dir in `tests/scenarios/` (teardown: `destroy` / destroy playbook, kept with `--skip-cleanup`). `--fixture-tags a,b` executes only fixtures whose tags intersect a,b; untagged matches are skipped as no-ops (test logic still runs against already deployed infra). `--skip-fixture-tags` is the inverse, `--skip-fixtures` skips all fixtures.

Dependency chain:

```
backup_scenario -> secondary_scenario -> k0s_edge_scenario
                                              ^
setup_k0s_bdd_server -------------------------
create_backup_qemu (independent)
```

### Fixtures, tags, and what they execute

| Fixture | Tags | Executes |
|---|---|---|
| `create_backup_qemu` | `qemu` | `playbooks/sync_qemus.yaml` (qemu stack `pytest-backup-qemu`, 75G system disk + 50G extra disk) + `playbooks/setup_backup_daemon.yaml` (BDD daemon, zfs vdev from the extra disk) → the primary backup daemon `pytest-backup-qemu.<domain>`; teardown `playbooks/destroy_qemus.yaml` |
| `setup_k0s_bdd_server` | `k0s`, `k0s-edge` | on the pre-deployed k0s node: creates `tank-ext` zpool on the 2nd scsi disk (if missing), then `playbooks/setup_backup_daemon.yaml` via an ext-hosts inventory (typed `backup_daemon` group) → k0s node doubles as BDD `pytest-k0s` |
| `backup_scenario` | `scenario` | `terraform apply tests/scenarios/backup` on the primary kubespray cluster: busybox source/restore deployments on ceph-csi sc (`test-backup-source`, `-restore`, `-restore-zfs`), root module (fetcher cron 20M bandwidth limit, bdd stack `pytest-backup-qemu`, node selector/tolerations), `pxc_helm_mirror` bitnami nginx release in the source namespace |
| `secondary_scenario` | `secondary` | `terraform apply tests/scenarios/secondary` on the secondary kubespray cluster: busybox on `openebs-zfspv-zvol` sc, root module pointed at the mc-gw host with `mc_ext_token` + `enable_ceph_csi_backups=false` (backups flow via the multi-cloud gateway to the primary BDD) |
| `k0s_edge_scenario` | `k0s-edge`, `k0s`, `k0s-tf` | `terraform apply tests/scenarios/k0s-edge` on the k0s cluster: `modules/k0s-edge-zfs-localpv` with `use_mc_gw_as_host=true` (bdd stack `pytest-k0s` — the k0s node is source and BDD) + busybox deployments on `openebs-zfspv-zvol` |

### Tests and required fixture tags

`tests/e2e/test_backup.py` — each full-cycle test: writes random content into the `test-backup-source` busybox pod, manually triggers the `fetcher-cron` job, verifies the archive on the BDD via `brctl` RPC (`list-backups`/`backup-details`), launches `brctl restore-k8s`, and asserts the restored file content. Pass the fixture tags of the scenario you changed; everything else stays skipped:

| Test | Fixture tags to pass | What it validates |
|---|---|---|
| `test_create_qemu` | `qemu` | fixture run only: backup qemu + BDD daemon creation/setup |
| `test_setup_k0s_bdd` | `k0s` (or `k0s-edge`) | fixture run only: BDD daemon on the k0s node (tank-ext zpool, ext-hosts inventory) |
| `test_backup` | `scenario` | primary ceph cluster full cycle: backup via direct BDD TLS, restore into `test-backup-restore` |
| `test_secondary_backup` | `secondary` | secondary openebs-zfspv cluster: backup via mc-gw to the primary BDD, restore with `--use-mc-gw` |
| `test_restore_zfs_ceph` | `scenario,secondary` | cross-CSI restore zfs→ceph: backup on secondary, restore on primary with `--sc-mapping openebs-zfspv-zvol:csi-rbd-sc-<pool>` |
| `test_restore_ceph_zfs` | `scenario,secondary` | inverse: backup on primary ceph, restore on secondary zfs via mc-gw with `--sc-mapping csi-rbd-sc-<pool>:openebs-zfspv-zvol` |
| `test_restore_k0s` | `k0s-tf` (or `k0s`/`k0s-edge`) | restore within the remote k0s node (k0s node is the BDD, `--use-mc-gw`) |
| `test_restore_ceph_k0s` | `scenario` + `k0s`/`k0s-tf`/`k0s-edge` | backup on primary ceph cluster, restore onto the remote k0s node via mc-gw + sc-mapping |

### Example invocations

```bash
# backup daemon / BDD qemu setup changes
pytest -s tests/e2e/test_backup.py::test_create_qemu --skip-cleanup --fixture-tags qemu

# root module / fetcher cron changes on the primary cluster
pytest -s tests/e2e/test_backup.py::test_backup --skip-cleanup --fixture-tags scenario

# secondary cluster / mc-gw backup path changes
pytest -s tests/e2e/test_backup.py::test_secondary_backup --skip-cleanup --fixture-tags secondary

# cross-CSI sc-mapping restore changes
pytest -s tests/e2e/test_backup.py::test_restore_zfs_ceph --skip-cleanup --fixture-tags scenario,secondary

# k0s bdd daemon setup changes
pytest -s tests/e2e/test_backup.py::test_setup_k0s_bdd --skip-cleanup --fixture-tags k0s

# k0s-edge-zfs-localpv module changes
pytest -s tests/e2e/test_backup.py::test_restore_k0s --skip-cleanup --fixture-tags k0s-tf

# ceph -> k0s restore path changes
pytest -s tests/e2e/test_backup.py::test_restore_ceph_k0s --skip-cleanup --fixture-tags scenario,k0s-tf

# re-run test logic only, against fully deployed infra
pytest -s tests/e2e/test_backup.py::test_backup --skip-cleanup --skip-fixtures
```
