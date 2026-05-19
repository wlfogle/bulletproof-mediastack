#!/usr/bin/env bash
# fix-permissions.sh — make /mnt/hdd globally read/writable, FOREVER.
#
# Approach (no watcher, no timer — just correct defaults):
#
#   1. Existing tree: `chmod -R a+rwX /mnt/hdd`
#        Capital X grants +x only to dirs / files that already had +x —
#        so we don't accidentally mark .mkv/.mp4 files executable.
#        After this: every dir is 0777, every file is 0666 (or 0777 if it
#        was already executable).
#
#   2. Default POSIX ACL: every new file/dir created under /mnt/hdd
#        automatically inherits world-rwx (dirs) / world-rw (files):
#            setfacl -R -d -m u::rwX,g::rwX,o::rwX /mnt/hdd
#
#   3. Daemons that write into /mnt/hdd (qbit, jd2, riven, sonarr, radarr,
#      bazarr, prowlarr, jellyseerr, riven-frontend) get a systemd drop-in
#      with `UMask=0000` so their newly created files come out 0666 instead
#      of being clamped down by the default 0022 umask.
#
#   4. Each running CT: `/etc` -> 0755 (we hit this on CT-300 once already),
#      and `/data` / `/data/media` mount points -> 0755.
#
# Idempotent. Safe to re-run. Run on the Proxmox host:
#     bash scripts/fix-permissions.sh

set -uo pipefail

HDDROOT="${HDDROOT:-/mnt/hdd}"

# Services that write into /mnt/hdd via /data bind-mount and need UMask=0000.
# Edit JF_CTS / WRITER_SERVICES if your stack changes.
WRITER_SERVICES_CT300=(
  qbittorrent-nox jdownloader2 riven riven-frontend
  sonarr radarr bazarr prowlarr jellyseerr jellyfin
)
WRITER_SERVICES_CT231=( jellyfin )
JF_CTS=( 300 231 )

C_INFO=$'\e[1;36m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_RST=$'\e[0m'
log()  { printf '%s[fix-perms]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s[fix-perms]%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '%s[fix-perms]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { warn "must run as root on the Proxmox host"; exit 1; }

############################################################################
# 1+2. /mnt/hdd: chmod existing tree + default ACL for the future
############################################################################
fix_hdd_root() {
  if [ ! -d "$HDDROOT" ]; then
    warn "$HDDROOT not present on this host — skipping"
    return 0
  fi

  log "auditing $HDDROOT (pre-fix)"
  local bad_dirs bad_files
  bad_dirs=$(find  "$HDDROOT" -xdev -type d ! -perm -o+rwx 2>/dev/null | wc -l)
  bad_files=$(find "$HDDROOT" -xdev -type f ! -perm -o+rw  2>/dev/null | wc -l)
  log "  $bad_dirs dirs lacking world-rwx, $bad_files files lacking world-rw"

  if [ "$bad_dirs" -gt 0 ] || [ "$bad_files" -gt 0 ]; then
    log "applying chmod -R a+rwX (parallelized at top level)"
    find "$HDDROOT" -mindepth 1 -maxdepth 1 -print0 \
      | xargs -0 -r -n 1 -P 4 chmod -R a+rwX
    chmod a+rwX "$HDDROOT"
  fi

  if command -v setfacl >/dev/null 2>&1; then
    log "setting default POSIX ACL (new files inherit world-rwx)"
    setfacl    -m u::rwX,g::rwX,o::rwX "$HDDROOT"   2>/dev/null || true
    setfacl -d -m u::rwX,g::rwX,o::rwX "$HDDROOT"   2>/dev/null || true
    # Propagate default ACL into every existing dir
    find "$HDDROOT" -xdev -type d -print0 \
      | xargs -0 -r -n 100 -P 4 setfacl -d -m u::rwX,g::rwX,o::rwX 2>/dev/null || true
  else
    warn "setfacl not present — apt install acl on host to enable inheritance"
  fi

  ok "$HDDROOT normalized: dirs 0777, files 0666 (X bits preserved), default ACL set"
}

############################################################################
# 3. UMask=0000 drop-ins inside each Jellyfin CT for every writer service
############################################################################
fix_ct_umasks() {
  local ct="$1" ; shift
  local services=( "$@" )

  echo
  log "=== CT-$ct: UMask=0000 drop-ins ==="
  pct exec "$ct" -- bash -s -- "${services[@]}" <<'INNER'
set -uo pipefail
changed=0
for svc in "$@"; do
  unit="$(systemctl show -p FragmentPath --value "$svc.service" 2>/dev/null || true)"
  [ -n "$unit" ] && [ "$unit" != "n/a" ] || continue
  drop="/etc/systemd/system/${svc}.service.d"
  mkdir -p "$drop"
  if [ ! -f "$drop/umask.conf" ] || ! grep -q '^UMask=0000' "$drop/umask.conf"; then
    cat > "$drop/umask.conf" <<EOF
[Service]
UMask=0000
EOF
    echo "  drop-in: $drop/umask.conf"
    changed=$((changed+1))
  fi
done
if [ "$changed" -gt 0 ]; then
  systemctl daemon-reload
  for svc in "$@"; do
    systemctl is-active --quiet "$svc.service" && systemctl restart "$svc.service" \
      && echo "  restarted $svc"
  done
fi
[ "$changed" -eq 0 ] && echo "  (no changes)"
INNER
}

############################################################################
# 4. Per-CT /etc and /data hygiene (we hit /etc=0700 on CT-300 once)
############################################################################
fix_ct_paths() {
  local ct="$1"
  log "=== CT-$ct: /etc + /data path modes ==="
  pct exec "$ct" -- bash -s <<'INNER'
set -uo pipefail
fix() {
  local d="$1" want="$2"
  [ -d "$d" ] || return 0
  local cur=$(stat -c %a "$d")
  if [ "$cur" != "$want" ]; then
    chmod "$want" "$d"
    echo "  $d: $cur -> $want"
  fi
}
fix /etc 755
for d in /data /data/media /data/torrents \
         /data/media/tv /data/media/movies /data/media/music \
         /data/media/anime /data/media/books /data/media/audiobooks \
         /data/media/recordings; do
  fix "$d" 777
done
INNER
}

############################################################################
# main
############################################################################
fix_hdd_root

if command -v pct >/dev/null 2>&1; then
  for ct in $(pct list | awk 'NR>1 && $2=="running"{print $1}'); do
    fix_ct_paths "$ct"
  done
  for ct in "${JF_CTS[@]}"; do
    pct status "$ct" 2>/dev/null | grep -q running || continue
    case "$ct" in
      300) fix_ct_umasks "$ct" "${WRITER_SERVICES_CT300[@]}" ;;
      231) fix_ct_umasks "$ct" "${WRITER_SERVICES_CT231[@]}" ;;
    esac
  done
else
  warn "pct not on PATH — not on a Proxmox host. Skipping CT loop."
fi

############################################################################
# Post-fix audit
############################################################################
echo
log "post-fix audit of $HDDROOT"
left_d=$(find "$HDDROOT" -xdev -type d ! -perm -o+rwx 2>/dev/null | wc -l)
left_f=$(find "$HDDROOT" -xdev -type f ! -perm -o+rw  2>/dev/null | wc -l)
if [ "$left_d" -eq 0 ] && [ "$left_f" -eq 0 ]; then
  ok "$HDDROOT clean — every dir 0777-effective, every file 0666-effective"
else
  warn "remaining offenders:"
  find "$HDDROOT" -xdev -type d ! -perm -o+rwx -printf "  D %m %p\n" 2>/dev/null | head -20
  find "$HDDROOT" -xdev -type f ! -perm -o+rw  -printf "  F %m %p\n" 2>/dev/null | head -20
fi

ok "done"
