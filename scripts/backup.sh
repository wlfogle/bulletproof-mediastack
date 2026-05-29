#!/bin/bash
# ============================================================
# Backup Script — Proxmox containers + app data
# Run via cron: 0 3 * * * /opt/homelab-media-stack/scripts/backup.sh
# ============================================================
set -e

BACKUP_DIR="/mnt/hdd/backups"
DATE=$(date +%Y-%m-%d)
LOG="/var/log/homelab-backup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

log "=== Starting backup ==="

mkdir -p "$BACKUP_DIR/lxc" "$BACKUP_DIR/appdata"

# ── Backup LXC containers ───────────────────────────────
log "Backing up LXC containers..."
# Infrastructure + Download + Media + Management + AI (skip VMs — too large for nightly)
for CTID in 300 501 900; do
  if pct status $CTID &>/dev/null; then
    log "  Backing up CT-${CTID}..."
    vzdump $CTID \
      --dumpdir "$BACKUP_DIR/lxc" \
      --compress zstd \
      --mode snapshot \
      --mailnotification never \
      --notes-template "Backup ${DATE}" 2>> "$LOG"
    log "  CT-${CTID} done"
  fi
done

# ── Backup app data configs ─────────────────────────────
log "Backing up appdata configs..."

tar -czf "$BACKUP_DIR/appdata/appdata-${DATE}.tar.gz" \
  --exclude='/opt/appdata/jellyfin/cache' \
  --ignore-failed-read \
  /opt/appdata/ 2>> "$LOG"

# ── Rotate backups (keep 7 days) ────────────────────────
log "Rotating old backups (keeping 7 days)..."
find "$BACKUP_DIR/lxc" -name "*.zst" -mtime +7 -delete
find "$BACKUP_DIR/appdata" -name "*.tar.gz" -mtime +7 -delete

log "=== Backup complete ==="
log "Backup location: $BACKUP_DIR"
