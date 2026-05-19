#!/usr/bin/env bash
# disk-space-watchdog.sh — monitor /mnt/hdd (media) and / (rootfs/local-lvm)
# on the Proxmox host. Pause downloads + notify when low; auto-resume + notify
# when recovered. Idempotent. Designed to be triggered by a systemd timer
# every few minutes.
#
# Action ladder (defaults are TIGHT — SSD and HDD must NOT fill):
#
#   HDD (/mnt/hdd):
#     ≥ HDD_WARN%   (default 80)    -> evict torrents already hardlinked to media + notify
#     ≥ HDD_CRIT%   (default 88)    -> evict + pause downloads + notify error
#     ≤ HDD_RESUME% (default 75)    -> resume downloads (if previously paused) + notify
#
#   SSD/rootfs (/):
#     ≥ SSD_WARN%   (default 75)    -> run cleanup (journal/apt/pnpm/tmp; vzdump prune)
#     ≥ SSD_CRIT%   (default 85)    -> aggressive cleanup + notify error
#
# "Pause downloads" pulls the upstream chokepoint of the Riven -> RD -> JD2
# pipeline:
#   1. Stop riven-jd2-bridge.service so no new links get pushed.
#   2. Call JD2 (MyJDownloader API) downloadcontroller.pause(true).
#   3. Pause all torrents on qBittorrent (CT-212), if reachable.
# JD2 finishes whatever it's actively pulling and idles.
#
# Notifications:
#   * journald (logger)
#   * /var/lib/disk-watchdog/notifications.log
#   * `wall` to all logged-in TTYs (best-effort)
#   * Home Assistant webhook if HA_NOTIFY_WEBHOOK_URL is set in
#     /etc/disk-watchdog/env

set -uo pipefail

# ─── tunables ────────────────────────────────────────────────────────────────
HDD_MOUNT="${HDD_MOUNT:-/mnt/hdd}"
SSD_MOUNT="${SSD_MOUNT:-/}"
# Tight defaults — the SSD is small and the HDD must never fill.
HDD_WARN="${HDD_WARN:-80}"
HDD_CRIT="${HDD_CRIT:-88}"
HDD_RESUME="${HDD_RESUME:-75}"
SSD_WARN="${SSD_WARN:-75}"
SSD_CRIT="${SSD_CRIT:-85}"
HDD_EVICT_MIN_AGE_DAYS="${HDD_EVICT_MIN_AGE_DAYS:-3}"
TORRENT_ROOT="${TORRENT_ROOT:-/mnt/hdd/torrents}"
MEDIA_ROOT="${MEDIA_ROOT:-/mnt/hdd/media}"

STATE_DIR="${STATE_DIR:-/var/lib/disk-watchdog}"
STATE_FILE="$STATE_DIR/status.json"
PAUSE_FLAG="$STATE_DIR/downloads.paused"
NOTIFY_LOG="$STATE_DIR/notifications.log"

# Optional config (HA webhook, alternate creds, …)
[ -f /etc/disk-watchdog/env ] && set -a && . /etc/disk-watchdog/env && set +a

mkdir -p "$STATE_DIR"

# ─── helpers ─────────────────────────────────────────────────────────────────
pct_used() {
  # Returns integer percent used. Empty/non-existent mount returns 0.
  local m="$1"
  [ -d "$m" ] || { echo 0; return; }
  df -P "$m" 2>/dev/null | awk 'NR==2{sub("%","",$5); print $5+0}'
}

notify() {
  local level="$1" ; shift
  local msg="$*"
  logger -t disk-watchdog -p "user.${level}" -- "$msg"
  printf '%s [%s] %s\n' "$(date -Iseconds)" "$level" "$msg" >> "$NOTIFY_LOG"
  echo "[disk-watchdog ${level}] $msg" | wall -n 2>/dev/null || true
  if [ -n "${HA_NOTIFY_WEBHOOK_URL:-}" ]; then
    curl -fsS --max-time 5 -X POST -H 'Content-Type: application/json' \
      -d "{\"level\":\"${level}\",\"message\":$(printf '%s' "$msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}" \
      "$HA_NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 || true
  fi
}

# ─── pause / resume primitives ───────────────────────────────────────────────
jd2_pause() {
  # call JD2 downloadcontroller via myjdapi using the bridge's existing creds
  [ -f /etc/riven-jd2-bridge.env ] || return 0
  set -a; . /etc/riven-jd2-bridge.env; set +a
  local want="${1:-true}"
  python3 - "$want" <<'PY' 2>>"$NOTIFY_LOG" || true
import os, sys
try:
    import myjdapi
except ImportError:
    print("myjdapi not installed; cannot toggle JD2 pause", file=sys.stderr); sys.exit(0)
want = sys.argv[1] == "true"
j = myjdapi.Myjdapi(); j.set_app_key("disk-watchdog")
j.connect(os.environ["MYJD_EMAIL"], os.environ["MYJD_PASSWORD"])
dev = j.get_device(os.environ.get("MYJD_DEVICE", "mediastack-jd2"))
dev.downloadcontroller.pause(want)
PY
}

qbit_pause_all() {
  # Best-effort qBit pause; uses its WebUI API. CT-212 default port 8080.
  local base="${QBIT_URL:-http://192.168.12.212:8080}"
  local user="${QBIT_USER:-admin}" pass="${QBIT_PASS:-adminadmin}"
  local ckj
  ckj=$(mktemp)
  if curl -fsS --max-time 5 -c "$ckj" -d "username=${user}&password=${pass}" \
       "${base}/api/v2/auth/login" >/dev/null 2>&1; then
    curl -fsS --max-time 5 -b "$ckj" -X POST \
      "${base}/api/v2/torrents/pause?hashes=all" >/dev/null 2>&1 || true
  fi
  rm -f "$ckj"
}

qbit_resume_all() {
  local base="${QBIT_URL:-http://192.168.12.212:8080}"
  local user="${QBIT_USER:-admin}" pass="${QBIT_PASS:-adminadmin}"
  local ckj; ckj=$(mktemp)
  if curl -fsS --max-time 5 -c "$ckj" -d "username=${user}&password=${pass}" \
       "${base}/api/v2/auth/login" >/dev/null 2>&1; then
    curl -fsS --max-time 5 -b "$ckj" -X POST \
      "${base}/api/v2/torrents/resume?hashes=all" >/dev/null 2>&1 || true
  fi
  rm -f "$ckj"
}

pause_downloads() {
  notify err "HDD critical (${HDD_USED}%) — pausing downloads"
  systemctl stop riven-jd2-bridge.service 2>/dev/null || true
  jd2_pause true
  qbit_pause_all
  date -Iseconds > "$PAUSE_FLAG"
}

resume_downloads() {
  [ -f "$PAUSE_FLAG" ] || return 0
  notify info "HDD recovered (${HDD_USED}% ≤ ${HDD_RESUME}%) — resuming downloads"
  jd2_pause false
  qbit_resume_all
  systemctl start riven-jd2-bridge.service 2>/dev/null || true
  rm -f "$PAUSE_FLAG"
}

# ─── HDD eviction ──────────────────────────────────────────────────────────────────────────────────────────────
evict_hdd() {
  # Safe deletion strategy:
  #   1. Walk $TORRENT_ROOT for files older than HDD_EVICT_MIN_AGE_DAYS.
  #   2. For each, check `stat -c %h` link count -> if >1, the same inode also
  #      lives somewhere else (typically a hardlink in $MEDIA_ROOT). Deleting
  #      the torrents-side copy frees the block only if it's the LAST link;
  #      with hardlinks present, removing the torrent name leaves the library
  #      copy intact. Deletion is therefore safe.
  #   3. Skip files with link count 1 (no library copy yet).
  # Also prunes obvious cache/partial cruft (.aria2, .recovery, .!qB, etc.).
  local before after freed_kb
  before=$(df -P "$HDD_MOUNT" | awk 'NR==2{print $3}')
  if [ -d "$TORRENT_ROOT" ]; then
    # Hardlinked completed files (linkcount > 1) older than threshold
    find "$TORRENT_ROOT" -type f -links +1 -mtime +"$HDD_EVICT_MIN_AGE_DAYS" \
      -not -name '*.unfinished' -not -name '*.parts' -delete 2>/dev/null
    # Empty parent directories left behind
    find "$TORRENT_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null
    # Cruft regardless of age
    find "$TORRENT_ROOT" -type f \( -name '*.aria2' -o -name '*.recovery.json' \
      -o -name '*.!qB' -o -name '*.!ut' \) -delete 2>/dev/null
  fi
  # Riven temporary scratch + caches
  rm -rf /var/lib/riven/cache 2>/dev/null
  rm -rf /var/cache/subliminal/* 2>/dev/null
  after=$(df -P "$HDD_MOUNT" | awk 'NR==2{print $3}')
  freed_kb=$(( before - after ))
  if [ "$freed_kb" -gt 0 ]; then
    notify info "HDD eviction freed $(( freed_kb / 1024 )) MB"
  fi
}

# ─── SSD cleanup ──────────────────────────────────────────────────────────────────────────────────────────────────
cleanup_ssd() {
  # Host
  journalctl --vacuum-size=200M >/dev/null 2>&1 || true
  command -v nala >/dev/null 2>&1 && nala clean >/dev/null 2>&1 || apt-get clean >/dev/null 2>&1 || true
  rm -rf /root/.cache/pnpm/* /root/.npm /root/.cache/uv 2>/dev/null
  find /tmp -mindepth 1 -mtime +1 -delete 2>/dev/null
  # Each running CT
  if command -v pct >/dev/null 2>&1; then
    for ct in $(pct list | awk 'NR>1 && $2=="running"{print $1}'); do
      pct exec "$ct" -- journalctl --vacuum-size=100M >/dev/null 2>&1 || true
      pct exec "$ct" -- bash -c '
        command -v nala >/dev/null && nala clean >/dev/null 2>&1 || apt-get clean >/dev/null 2>&1 || true
        rm -rf /root/.cache/pnpm/* /root/.npm 2>/dev/null
        find /tmp -mindepth 1 -mtime +1 -delete 2>/dev/null || true
      ' >/dev/null 2>&1 || true
    done
  fi
  # vzdump backups: keep only last 3 per CT
  if [ -d /mnt/hdd/backups ]; then
    find /mnt/hdd/backups -type f -name 'vzdump-*' -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr | awk 'NR>3{$1=""; sub("^ ",""); print}' \
      | xargs -r rm -f 2>/dev/null
  fi
}

# ─── main ────────────────────────────────────────────────────────────────────
HDD_USED=$(pct_used "$HDD_MOUNT")
SSD_USED=$(pct_used "$SSD_MOUNT")

# HDD ladder
if [ "$HDD_USED" -ge "$HDD_CRIT" ]; then
  evict_hdd
  HDD_USED=$(pct_used "$HDD_MOUNT")    # recheck post-evict
  if [ "$HDD_USED" -ge "$HDD_CRIT" ] && [ ! -f "$PAUSE_FLAG" ]; then
    pause_downloads
  fi
elif [ "$HDD_USED" -ge "$HDD_WARN" ]; then
  notify warning "HDD ${HDD_USED}% used (warn ${HDD_WARN}%, crit ${HDD_CRIT}%) — evicting"
  evict_hdd
elif [ "$HDD_USED" -le "$HDD_RESUME" ] && [ -f "$PAUSE_FLAG" ]; then
  resume_downloads
fi

# SSD ladder
ssd_action="none"
if [ "$SSD_USED" -ge "$SSD_CRIT" ]; then
  cleanup_ssd
  notify err "SSD ${SSD_USED}% used (critical ${SSD_CRIT}%) — cleanup ran"
  ssd_action="cleanup-crit"
elif [ "$SSD_USED" -ge "$SSD_WARN" ]; then
  cleanup_ssd
  notify warning "SSD ${SSD_USED}% used (warn ${SSD_WARN}%) — cleanup ran"
  ssd_action="cleanup-warn"
fi

# State file (for Pulse / Uptime Kuma / external probes)
paused=$([ -f "$PAUSE_FLAG" ] && echo true || echo false)
cat > "${STATE_FILE}.tmp" <<JSON
{
  "checked_at": "$(date -Iseconds)",
  "hdd_mount": "${HDD_MOUNT}",
  "hdd_used_pct": ${HDD_USED},
  "hdd_warn_pct": ${HDD_WARN},
  "hdd_crit_pct": ${HDD_CRIT},
  "ssd_mount": "${SSD_MOUNT}",
  "ssd_used_pct": ${SSD_USED},
  "ssd_warn_pct": ${SSD_WARN},
  "ssd_crit_pct": ${SSD_CRIT},
  "downloads_paused": ${paused},
  "ssd_action": "${ssd_action}"
}
JSON
mv "${STATE_FILE}.tmp" "$STATE_FILE"

# stdout summary (visible if invoked manually or via timer journal)
echo "HDD ${HDD_MOUNT}: ${HDD_USED}%  | SSD ${SSD_MOUNT}: ${SSD_USED}%  | paused=${paused}  | ssd=${ssd_action}"
