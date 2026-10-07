# Agent Instructions

The root terraform module deploys the backup stack into a Proxmox Cloud k8s cluster: `fetcher-cron` cron job (ceph csi volume snapshots → borg archives on the BDD), `fetcher-config`/`fetcher-secrets`/`fetcher-tls-ca` config, and the secrets needed to launch `brctl restore-k8s` jobs. Backups are sent directly to the BDD (via TLS discovery secret) or proxied through the multi-cloud gateway (`backup_daemon_address` + `mc_ext_token`).

## Testing

Ignore the tests under `tests/e2e` and `tests/scenarios`, these are tests executed by real developers on a running test environment you dont have access to.

For validation create, tests in the `tests/unit` directory, run these with prefixed with `terraform test -test-directory=tests/unit`. 

## Submodules (`modules/`)

- **access-namespace** — Standalone access/restore setup for a namespace only (no cron job), for clusters that just need to restore from an existing `pve-cloud-backup` server via `brctl`.
- **k0s-edge-zfs-localpv** — Stripped-down variant for external non-PXC k0s edge systems with zfs csi underneath; configures backup cron + restores funneling to any BDD (`use_mc_gw_as_host`).
