# Backups

> **Updated 2026-07-11:** Architecture consolidated to CT-300 + CT-501. All old per-service
> CTs (100–279, 900) are decommissioned. Backup targets and scripts below reflect current state.

## Current State
`scripts/backup.sh` runs daily at **03:00** via `/etc/cron.d/vzdump` on Tiamat.

What it does:
1. **vzdump snapshot** of active CTs/VMs → `/mnt/hdd/backups/lxc/` (zstd compressed)
2. **appdata tar** of CT-300 `/opt/appdata/` → `/mnt/hdd/backups/appdata/appdata-DATE.tar.gz`
3. **Vaultwarden backup** already at `/var/backup/mediastack/vaultwarden_pg_dump.sql` + `vaultwarden_data.tgz` in CT-300
4. **Rotation** — keeps 7 days of each

Current backup targets:

| VMID | Name | Priority | Notes |
|---|---|---|---|
| CT-300 | mediastack | **Critical** | Jellyfin, Riven, n8n, Caddy, Postgres, Redis, Vaultwarden |
| CT-501 | habridge | High | Alexa/Hue voice bridge |
| VM-990 | haos | High | Home Assistant OS — backup before HA upgrades |
| VM-100 | openwrt | Medium | OpenWrt config — backup before network changes |
| VM-101 | win11vm | Low | Large disk; vzdump manually before major changes |

(VMs excluded from nightly by default — too large; vzdump manually before major changes)

Log: `/var/log/homelab-backup.log`

## Planned — Restic (not yet deployed)
Restic will supplement vzdump with a deduplicated, prunable appdata backup.
Destination: `/mnt/hdd/backups/restic`

Install when ready:
```bash
apt install -y restic
export RESTIC_REPOSITORY=/mnt/hdd/backups/restic
export RESTIC_PASSWORD='change-this'
restic init
```
Schedule at 03:30 (30 min after vzdump finishes):
```bash
30 3 * * * root restic -r /mnt/hdd/backups/restic --password-file /root/.restic-pass backup /opt/appdata >> /var/log/restic-backup.log 2>&1
```
Retention:
```bash
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 3
```
## Restore
Vzdump restore (from Proxmox UI or CLI):
```bash
# List available backups
ls /mnt/hdd/backups/lxc/
# Restore CT-300
pct restore 300 /mnt/hdd/backups/lxc/vzdump-lxc-300-*.tar.zst --storage hdd-ct
# Restore VM-990 Home Assistant
qmrestore /mnt/hdd/backups/lxc/vzdump-qemu-990-*.vma.zst 990 --storage local-lvm
```
Restic restore (once deployed):
```bash
restic snapshots
restic restore latest --target /tmp/restic-restore --include /opt/appdata/sonarr
```
## Notes
- Test restore monthly — a backup never tested is not a backup.
- Move restic password to a root-only file: `echo 'yourpassword' > /root/.restic-pass && chmod 600 /root/.restic-pass`
