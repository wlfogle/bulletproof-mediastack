#!/usr/bin/env bash
# =============================================================================
# bulletproof-mediastack — single-script deploy
#
# Replaces the *arr stack entirely. Architecture:
#
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │ CT-300 mediastack  (Proxmox LXC, privileged, Debian 12)              │
#   │  ┌────────┐   ┌────────┐   ┌────────────┐   ┌─────────┐             │
#   │  │ Riven  │ → │  zurg  │ → │ rclone     │ ← │ Jellyfin│             │
#   │  │  UI +  │   │ (RD WebDAV│  │ /mnt/zurg │   │ (scans) │             │
#   │  │ scraper│   │  proxy)  │  │  mount    │   │         │             │
#   │  └────────┘   └────────┘   └────────────┘   └─────────┘             │
#   │     ↑                                                                │
#   │ user request                                                         │
#   └──────────────────────────────────────────────────────────────────────┘
#
# Flow:
#   1. User searches & adds in Riven UI    (port 3000)
#   2. Riven adds magnet to Real-Debrid    (RD API)
#   3. zurg notices the new RD entry       (~5-10 sec)
#   4. rclone exposes it at /mnt/zurg as a real filesystem
#   5. Riven creates a symlink in /mnt/library/{movies,shows} → /mnt/zurg/...
#   6. Jellyfin's real-time monitor sees the symlink, scans, makes available
#   7. Total: ~30-60 sec from request to playable
#
# What's gone vs *arr stack:
#   • no qBittorrent, no RDT-Client (Riven talks to RD directly)
#   • no Sonarr / Radarr / Prowlarr / Bazarr / Jellyseerr
#   • no /mnt/media on disk (all served from RD via rclone — 0 bytes locally)
#   • no SQLite WAL contention (no *arr DBs)
#   • no Jellyfin Connect webhook config drift (Riven creates symlinks
#     directly, Jellyfin's real-time monitor handles the rest)
#
# REQUIREMENTS (provide via env or .env file):
#   RD_API_TOKEN          Real-Debrid API token (from real-debrid.com/apitoken)
#   TZ                    timezone, e.g. America/New_York
#
# Run on Proxmox host (Tiamat) as root:
#   bash /opt/bulletproof-mediastack/scripts/deploy.sh
#
# Env overrides (sane defaults provided):
#   CTID=300                       container ID
#   CT_HOSTNAME=mediastack
#   IP=192.168.12.30/24
#   GATEWAY=192.168.12.1
#   STORAGE=local-lvm              Proxmox storage pool for rootfs
#   ROOTFS_GB=16
#   RAM_MB=4096                    Riven scrapers like 4 GB
#   CORES=4
#   TEMPLATE=local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst
#   FORCE_RECREATE=0               1 = wipe existing CT-300 first
# =============================================================================
set -Eeuo pipefail

CTID="${CTID:-300}"
# NOTE: HOSTNAME is a bash built-in ("$HOSTNAME" = the host's own name); use
# a non-conflicting var name so the default actually applies.
CT_HOSTNAME="${CT_HOSTNAME:-mediastack}"
IP="${IP:-192.168.12.30/24}"
GATEWAY="${GATEWAY:-192.168.12.1}"
STORAGE="${STORAGE:-local-lvm}"
ROOTFS_GB="${ROOTFS_GB:-16}"
RAM_MB="${RAM_MB:-4096}"
CORES="${CORES:-4}"
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst}"
TZ="${TZ:-America/New_York}"
DNS="${DNS:-8.8.8.8 1.1.1.1}"
BRIDGE="${BRIDGE:-vmbr0}"
FORCE_RECREATE="${FORCE_RECREATE:-0}"

# Optional .env in the same directory
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "${SCRIPT_DIR}/../.env" ]; then
  # shellcheck disable=SC1091
  set -a; source "${SCRIPT_DIR}/../.env"; set +a
fi

: "${RD_API_TOKEN:?Real-Debrid API token required. Set RD_API_TOKEN in env or .env}"

info()  { printf '\033[1;36m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
step()  { printf '\n\033[1;35m── %s ──\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { err "Must run as root on Proxmox host."; exit 1; }
command -v pct >/dev/null 2>&1 || { err "pct not found. Run on a Proxmox host."; exit 1; }

step "Bulletproof deploy → CT-${CTID} (${CT_HOSTNAME})"

# ── 0. Ensure Debian 12 template ─────────────────────────────────────────────
if ! pveam list local 2>/dev/null | grep -q 'debian-12-standard'; then
  info "Downloading Debian 12 template ..."
  pveam update >/dev/null 2>&1 || true
  pveam download local debian-12-standard_12.12-1_amd64.tar.zst >/dev/null
fi

# ── 1. (Re)create privileged CT ──────────────────────────────────────────────
if [ "$FORCE_RECREATE" = "1" ] && pct status "$CTID" >/dev/null 2>&1; then
  info "FORCE_RECREATE=1 — destroying CT-${CTID} ..."
  pct stop "$CTID" >/dev/null 2>&1 || true
  pct destroy "$CTID" --purge 1 --destroy-unreferenced-disks 1 >/dev/null
fi

if pct status "$CTID" >/dev/null 2>&1; then
  info "CT-${CTID} already exists — skipping create."
else
  info "Creating privileged CT-${CTID} (${CORES}c/${RAM_MB}M/${ROOTFS_GB}G) ..."
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" --memory "$RAM_MB" --swap "$((RAM_MB/2))" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY},type=veth" \
    --nameserver "$DNS" \
    --storage "$STORAGE" --rootfs "${STORAGE}:${ROOTFS_GB}" \
    --unprivileged 0 \
    --features "nesting=1,keyctl=1,fuse=1" \
    --onboot 1 \
    --start 0 >/dev/null
  ok "CT-${CTID} created (privileged)."
fi

# ── 2. Add /dev/dri (VAAPI) and /dev/fuse (rclone needs it) ──────────────────
CONF="/etc/pve/lxc/${CTID}.conf"
add_line() { grep -qxF "$1" "$CONF" || echo "$1" >>"$CONF"; }
add_line "lxc.cgroup2.devices.allow: c 226:0 rwm"
add_line "lxc.cgroup2.devices.allow: c 226:128 rwm"
add_line "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
add_line "lxc.cgroup2.devices.allow: c 10:229 rwm"
add_line "lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file"
add_line "lxc.apparmor.profile: unconfined"

# ── 3. Start CT ──────────────────────────────────────────────────────────────
if [ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]; then
  pct start "$CTID" >/dev/null
  sleep 6
fi
for _ in $(seq 1 60); do
  pct exec "$CTID" -- true 2>/dev/null && break
  sleep 1
done

# ── 4. Bootstrap inside CT: packages + users ─────────────────────────────────
info "Installing packages inside CT-${CTID} ..."
pct exec "$CTID" -- bash <<'BOOT'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends -qq \
  ca-certificates curl wget gnupg lsb-release apt-transport-https \
  python3 python3-pip python3-venv \
  git jq sqlite3 fuse3 \
  tzdata cron sudo \
  postgresql postgresql-contrib

# Real-Debrid: just need internet. Verify.
curl -fsS https://api.real-debrid.com >/dev/null || { echo "no internet to RD"; exit 1; }

# Jellyfin repo
install -d /usr/share/keyrings
curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/jellyfin.gpg] https://repo.jellyfin.org/master/debian bookworm main" \
  >/etc/apt/sources.list.d/jellyfin.list

# rclone — official .deb (newer than apt)
RCLONE_URL=$(curl -fsSL https://api.github.com/repos/rclone/rclone/releases/latest \
  | jq -r '.assets[] | select(.name|test("amd64\\.deb$")) | .browser_download_url' | head -1)
curl -fsSL "$RCLONE_URL" -o /tmp/rclone.deb
apt-get install -y /tmp/rclone.deb
rm /tmp/rclone.deb

apt-get update -qq
apt-get install -y --no-install-recommends -qq jellyfin jellyfin-ffmpeg7

# Service users
getent group media >/dev/null || groupadd -g 1000 media
id -u zurg     >/dev/null 2>&1 || useradd -r -m -d /var/lib/zurg     -s /usr/sbin/nologin -g media zurg
id -u rclone   >/dev/null 2>&1 || useradd -r -m -d /var/lib/rclone   -s /usr/sbin/nologin -g media rclone
id -u riven    >/dev/null 2>&1 || useradd -r -m -d /var/lib/riven    -s /usr/sbin/nologin -g media riven
usermod -aG media jellyfin

# Jellyfin VAAPI groups
groupadd -g 993 render 2>/dev/null || groupmod -g 993 render
groupadd -g 44  video  2>/dev/null || groupmod -g 44  video
usermod -aG video,render jellyfin

# Allow non-root mount via fuse
echo 'user_allow_other' >/etc/fuse.conf
BOOT
ok "Packages installed."

# ── 5. Install zurg ──────────────────────────────────────────────────────────
info "Installing zurg (Real-Debrid WebDAV) ..."
pct exec "$CTID" -- bash <<'ZURG'
set -Eeuo pipefail
ZURG_URL=$(curl -fsSL https://api.github.com/repos/debridmediamanager/zurg-testing/releases/latest \
  | jq -r '.assets[] | select(.name|test("linux-amd64$")) | .browser_download_url' | head -1)
curl -fsSL "$ZURG_URL" -o /usr/local/bin/zurg
chmod +x /usr/local/bin/zurg
mkdir -p /etc/zurg /var/lib/zurg
chown -R zurg:media /etc/zurg /var/lib/zurg
ZURG

# Config + token
pct exec "$CTID" -- bash -c "cat >/etc/zurg/config.yml <<CFG
zurg: v1
token: ${RD_API_TOKEN}
host: 0.0.0.0
port: 9999
concurrent_workers: 32
check_for_changes_every_secs: 10
ignore_renames: true
retain_rd_torrent_name: true
retain_folder_name_extension: false
enable_repair: true
auto_delete_rar_torrents: true
api_rate_limit_per_minute: 60
torrents_rate_limit_per_minute: 25
serve_from_rclone: false
verify_download_link: true
network_buffer_size: 4194304
directories:
  shows:
    group_order: 10
    group: media
    filters:
      - regex: /\\bs\\d+(e\\d+)?\\b/i
      - regex: /\\b(season|episode)\\b/i
  movies:
    group_order: 20
    group: media
    only_show_the_biggest_file: true
    filters:
      - regex: /.*/
CFG
chown zurg:media /etc/zurg/config.yml
chmod 0640 /etc/zurg/config.yml"

pct exec "$CTID" -- bash <<'ZUNIT'
cat >/etc/systemd/system/zurg.service <<UNIT
[Unit]
Description=Zurg (Real-Debrid WebDAV)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=zurg
Group=media
WorkingDirectory=/var/lib/zurg
ExecStart=/usr/local/bin/zurg --config /etc/zurg/config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now zurg
ZUNIT
ok "zurg running on port 9999."

# ── 6. rclone mount of zurg's WebDAV ─────────────────────────────────────────
info "Configuring rclone mount of zurg → /mnt/zurg ..."
pct exec "$CTID" -- bash <<'RC'
set -Eeuo pipefail
mkdir -p /etc/rclone /mnt/zurg
chown rclone:media /mnt/zurg
chmod 0775 /mnt/zurg
cat >/etc/rclone/rclone.conf <<CFG
[zurg]
type = webdav
url = http://127.0.0.1:9999/dav
vendor = other
pacer_min_sleep = 0
CFG
chown rclone:media /etc/rclone/rclone.conf
chmod 0640 /etc/rclone/rclone.conf

cat >/etc/systemd/system/rclone-zurg.service <<UNIT
[Unit]
Description=rclone mount: zurg WebDAV → /mnt/zurg
After=zurg.service
Requires=zurg.service

[Service]
Type=notify
User=rclone
Group=media
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/rclone mount zurg: /mnt/zurg \
  --config=/etc/rclone/rclone.conf \
  --allow-other \
  --uid=1000 --gid=1000 --umask=002 \
  --dir-cache-time=10s \
  --vfs-cache-mode=full \
  --vfs-cache-max-size=4G \
  --vfs-cache-max-age=24h \
  --buffer-size=64M \
  --attr-timeout=8700h \
  --poll-interval=15s
ExecStop=/bin/fusermount3 -u /mnt/zurg
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now rclone-zurg
RC
ok "rclone mount active at /mnt/zurg."

# ── 7. Riven (request UI + RD scraper + symlink library builder) ─────────────
info "Installing Riven backend + frontend ..."
pct exec "$CTID" -- bash <<'RIVEN'
set -Eeuo pipefail
# PostgreSQL setup
systemctl enable --now postgresql
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='riven'" | grep -q 1 || \
  sudo -u postgres psql <<SQL
CREATE USER riven WITH PASSWORD 'riven';
CREATE DATABASE riven OWNER riven;
SQL

# Riven backend
git clone https://github.com/rivenmedia/riven.git /opt/riven 2>/dev/null || git -C /opt/riven pull
chown -R riven:media /opt/riven
sudo -u riven python3 -m venv /opt/riven/.venv
sudo -u riven /opt/riven/.venv/bin/pip install --quiet --upgrade pip poetry
cd /opt/riven && sudo -u riven /opt/riven/.venv/bin/poetry install --no-root --quiet

# Riven frontend
git clone https://github.com/rivenmedia/riven-frontend.git /opt/riven-frontend 2>/dev/null || git -C /opt/riven-frontend pull
cd /opt/riven-frontend
apt-get install -y --no-install-recommends -qq nodejs npm
npm install --silent
npm run build --silent
chown -R riven:media /opt/riven-frontend

# Library symlink target (where Riven creates symlinks pointing into /mnt/zurg)
mkdir -p /mnt/library/movies /mnt/library/shows
chown -R riven:media /mnt/library
chmod -R 0775 /mnt/library

# Riven backend systemd
cat >/etc/systemd/system/riven.service <<UNIT
[Unit]
Description=Riven backend
After=network-online.target rclone-zurg.service postgresql.service
Requires=rclone-zurg.service postgresql.service

[Service]
Type=simple
User=riven
Group=media
WorkingDirectory=/opt/riven
Environment="RIVEN_RD_API_KEY=__RD_API_TOKEN__"
Environment="RIVEN_DATABASE_HOST=postgresql+psycopg2://riven:riven@127.0.0.1/riven"
Environment="RIVEN_FORCE_REFRESH_LIBRARY=true"
Environment="RIVEN_SYMLINK_LIBRARY_PATH=/mnt/library"
Environment="RIVEN_SYMLINK_RCLONE_PATH=/mnt/zurg"
Environment="RIVEN_LOG=true"
Environment="RIVEN_HOST=0.0.0.0"
Environment="RIVEN_PORT=8080"
ExecStart=/opt/riven/.venv/bin/python -m src.main
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# Riven frontend systemd
cat >/etc/systemd/system/riven-frontend.service <<UNIT
[Unit]
Description=Riven frontend
After=riven.service
Requires=riven.service

[Service]
Type=simple
User=riven
Group=media
WorkingDirectory=/opt/riven-frontend
Environment="ORIGIN=http://0.0.0.0:3000"
Environment="BACKEND_URL=http://127.0.0.1:8080"
ExecStart=/usr/bin/node build
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
RIVEN

# Splice in the real RD token
pct exec "$CTID" -- sed -i "s|__RD_API_TOKEN__|${RD_API_TOKEN}|" /etc/systemd/system/riven.service

pct exec "$CTID" -- bash -c '
systemctl daemon-reload
systemctl enable --now riven riven-frontend
'
ok "Riven backend (8080) + frontend (3000) running."

# ── 8. Jellyfin: scan /mnt/library and enable real-time monitor ──────────────
info "Configuring Jellyfin to scan /mnt/library ..."
pct exec "$CTID" -- bash <<'JF'
set -Eeuo pipefail
systemctl enable --now jellyfin
# Wait for first-run to write its config tree
for _ in $(seq 1 60); do
  [ -d /var/lib/jellyfin/config ] && break
  sleep 2
done
# Real-time monitor for any libraries that already exist
LIB_DIR="/var/lib/jellyfin/config/libraries"
if [ -d "$LIB_DIR" ]; then
  shopt -s nullglob
  for f in "$LIB_DIR"/*/options.xml; do
    if grep -q '<EnableRealtimeMonitor>' "$f"; then
      sed -i 's|<EnableRealtimeMonitor>false</EnableRealtimeMonitor>|<EnableRealtimeMonitor>true</EnableRealtimeMonitor>|' "$f"
    else
      sed -i 's|</LibraryOptions>|  <EnableRealtimeMonitor>true</EnableRealtimeMonitor>\n</LibraryOptions>|' "$f"
    fi
  done
  systemctl restart jellyfin
fi
JF
ok "Jellyfin running on port 8096 with real-time monitor."

# ── 9. Final summary ─────────────────────────────────────────────────────────
IP_ONLY="${IP%/*}"
cat <<EOF

============================================================
  bulletproof-mediastack — deployed in CT-${CTID} (${CT_HOSTNAME})
============================================================
  Riven UI       http://${IP_ONLY}:3000   ← request shows/movies here
  Riven API      http://${IP_ONLY}:8080
  Jellyfin       http://${IP_ONLY}:8096   ← watch here

  Internal:
    zurg WebDAV   http://${IP_ONLY}:9999/dav
    rclone mount  /mnt/zurg
    Library tree  /mnt/library  (symlinks created by Riven)

  Services (in CT-${CTID}):
    systemctl status zurg rclone-zurg riven riven-frontend jellyfin

  First-run setup:
    1. Open http://${IP_ONLY}:3000 in your browser.
    2. Riven first-run wizard: complete onboarding (2 minutes).
       It will autodetect the RD token from RIVEN_RD_API_KEY.
    3. In Jellyfin (http://${IP_ONLY}:8096): add libraries pointing at
         /mnt/library/movies   (Movies)
         /mnt/library/shows    (TV Shows)
       Enable real-time monitoring on each.
    4. Add a show or movie in Riven. Watch it appear in Jellyfin within
       ~30-60 seconds.

  No qBittorrent. No Sonarr. No Radarr. No Prowlarr. No /mnt/media disk.
  Request → watch in seconds. The pipeline is bulletproof.
============================================================
EOF
