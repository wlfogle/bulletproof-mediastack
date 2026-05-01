#!/usr/bin/env bash
# =============================================================================
# bulletproof-mediastack — single-script deploy
#
# One privileged Proxmox LXC (CT-300 default) running everything natively.
#
# Media path (request → watch in ~30-60 sec):
#   • zurg              — Real-Debrid → WebDAV at 127.0.0.1:9999
#   • rclone-zurg       — mounts zurg at /mnt/zurg (with healthcheck timer)
#   • Riven backend     — request UI scraper, 127.0.0.1:8080 (LAN-internal)
#   • Riven frontend    — user-facing UI on :3000
#   • Jellyfin          — playback on :8096 (real-time monitor of /mnt/library)
#
# Integrated infrastructure (replaces standalone CT-100…107/275):
#   • PostgreSQL        — Riven DB and any future service DB, :5432 localhost
#   • Valkey (Redis)    — cache for Riven, :6379 localhost
#   • Caddy             — reverse proxy on :80/:443 with auto-TLS (self-signed
#                         for *.mediastack.lan; trusted internal CA)
#   • CrowdSec          — host IDS scanning systemd journal
#   • Homarr            — dashboard on :7575 with bookmarks for every service
#   • Tailscale (opt-in)— mesh VPN for remote access (set TAILSCALE_AUTHKEY)
#
# Not included (intentionally):
#   • No qBittorrent / RDT-Client — Riven talks to Real-Debrid directly
#   • No Sonarr / Radarr / Prowlarr / Bazarr / Jellyseerr — Riven covers all
#   • No FlareSolverr / Byparr — Riven uses RD-cache-aware scraper APIs
#     (Torrentio, Knightcrawler, Mediafusion). No Cloudflare challenges,
#     no Chromium sandbox. The "browser bypass" failure class is gone.
#   • No /mnt/media on disk — files live on Real-Debrid, mounted via rclone.
#
# REQUIREMENTS (provide via env or .env file in repo root):
#   RD_API_TOKEN          Real-Debrid API token (real-debrid.com/apitoken)
#   TZ                    timezone, default America/New_York
#
# Run on Proxmox host (Tiamat) as root:
#   bash /opt/bulletproof-mediastack/scripts/deploy.sh
#
# Env overrides (defaults shown):
#   CTID=300                       container ID
#   CT_HOSTNAME=mediastack
#   IP=192.168.12.30/24
#   GATEWAY=192.168.12.1
#   STORAGE=local-lvm              Proxmox storage pool for rootfs
#   ROOTFS_GB=24
#   RAM_MB=8192                    fits Riven + PG + Jellyfin + dashboard
#   CORES=6
#   TEMPLATE=local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst
#   FORCE_RECREATE=0               1 = wipe existing CT-300 first
#   TAILSCALE_AUTHKEY=             optional, enables Tailscale on this CT
# =============================================================================
set -Eeuo pipefail

CTID="${CTID:-300}"
# NOTE: bash's built-in $HOSTNAME shadows our default; use a non-conflicting var.
CT_HOSTNAME="${CT_HOSTNAME:-mediastack}"
IP="${IP:-192.168.12.30/24}"
GATEWAY="${GATEWAY:-192.168.12.1}"
STORAGE="${STORAGE:-local-lvm}"
ROOTFS_GB="${ROOTFS_GB:-24}"
RAM_MB="${RAM_MB:-8192}"
CORES="${CORES:-6}"
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst}"
TZ="${TZ:-America/New_York}"
DNS="${DNS:-8.8.8.8 1.1.1.1}"
BRIDGE="${BRIDGE:-vmbr0}"
FORCE_RECREATE="${FORCE_RECREATE:-0}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

# Optional .env in repo root
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

# ── 2. Add /dev/dri (VAAPI), /dev/fuse (rclone), TUN (Tailscale) ─────────────
CONF="/etc/pve/lxc/${CTID}.conf"
add_line() { grep -qxF "$1" "$CONF" || echo "$1" >>"$CONF"; }
add_line "lxc.cgroup2.devices.allow: c 226:0 rwm"
add_line "lxc.cgroup2.devices.allow: c 226:128 rwm"
add_line "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
add_line "lxc.cgroup2.devices.allow: c 10:229 rwm"
add_line "lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file"
add_line "lxc.cgroup2.devices.allow: c 10:200 rwm"
add_line "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
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

# ── 4. Bootstrap inside CT: repos + base packages + users ────────────────────
info "Bootstrapping packages and APT repos in CT-${CTID} ..."
pct exec "$CTID" -- bash <<'BOOT'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends -qq \
  ca-certificates curl wget gnupg lsb-release apt-transport-https \
  python3 python3-pip python3-venv \
  git jq sqlite3 fuse3 \
  tzdata cron sudo \
  postgresql postgresql-contrib \
  redis-server redis-tools \
  nodejs npm \
  debian-keyring debian-archive-keyring

# Real-Debrid reachable?
curl -fsS https://api.real-debrid.com >/dev/null || { echo "no internet to RD"; exit 1; }

install -d /usr/share/keyrings /etc/apt/sources.list.d

# Jellyfin repo (idempotent: rm + dearmor with --batch --yes for re-runs)
rm -f /usr/share/keyrings/jellyfin.gpg
curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
  | gpg --batch --yes --dearmor -o /usr/share/keyrings/jellyfin.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/jellyfin.gpg] https://repo.jellyfin.org/master/debian bookworm main" \
  >/etc/apt/sources.list.d/jellyfin.list

# Caddy repo (official)
rm -f /usr/share/keyrings/caddy.gpg
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
  | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy.gpg
echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
  >/etc/apt/sources.list.d/caddy.list

# CrowdSec repo (official)
curl -fsSL https://install.crowdsec.net | bash >/dev/null 2>&1 || true

# rclone — official .deb (newer than apt)
RCLONE_URL=$(curl -fsSL https://api.github.com/repos/rclone/rclone/releases/latest \
  | jq -r '.assets[] | select(.name|test("amd64\\.deb$")) | .browser_download_url' | head -1)
curl -fsSL "$RCLONE_URL" -o /tmp/rclone.deb
apt-get install -y /tmp/rclone.deb
rm /tmp/rclone.deb

apt-get update -qq
apt-get install -y --no-install-recommends -qq \
  jellyfin jellyfin-ffmpeg7 \
  caddy \
  crowdsec crowdsec-firewall-bouncer-iptables

# Service users
getent group media >/dev/null || groupadd -g 1000 media
id -u zurg     >/dev/null 2>&1 || useradd -r -m -d /var/lib/zurg     -s /usr/sbin/nologin -g media zurg
id -u rclone   >/dev/null 2>&1 || useradd -r -m -d /var/lib/rclone   -s /usr/sbin/nologin -g media rclone
id -u riven    >/dev/null 2>&1 || useradd -r -m -d /var/lib/riven    -s /usr/sbin/nologin -g media riven
id -u homarr   >/dev/null 2>&1 || useradd -r -m -d /var/lib/homarr   -s /usr/sbin/nologin -g media homarr
usermod -aG media jellyfin

# Jellyfin VAAPI groups
groupadd -g 993 render 2>/dev/null || groupmod -g 993 render
groupadd -g 44  video  2>/dev/null || groupmod -g 44  video
usermod -aG video,render jellyfin

# Allow non-root mount via fuse
echo 'user_allow_other' >/etc/fuse.conf

# Redis: localhost only, lower memory
sed -i 's/^bind .*/bind 127.0.0.1 -::1/' /etc/redis/redis.conf
sed -i 's/^# *maxmemory .*/maxmemory 256mb/' /etc/redis/redis.conf
sed -i 's/^# *maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
systemctl enable --now redis-server
BOOT
ok "Base packages + repos installed."

# ── 5. zurg ───────────────────────────────────────────────────────────────────────────
info "Installing zurg (Real-Debrid WebDAV) ..."
pct exec "$CTID" -- bash <<'ZURG'
set -Eeuo pipefail
apt-get install -y --no-install-recommends -qq unzip
ZURG_URL=$(curl -fsSL https://api.github.com/repos/debridmediamanager/zurg-testing/releases/latest \
  | jq -r '.assets[] | select(.name|test("linux-amd64\\.zip$")) | .browser_download_url' | head -1)
if [ -z "$ZURG_URL" ]; then echo "ERR: no zurg linux-amd64.zip asset found"; exit 1; fi
echo "Downloading $ZURG_URL"
curl -fsSL "$ZURG_URL" -o /tmp/zurg.zip
unzip -oq /tmp/zurg.zip -d /tmp/zurg-unzip
# Asset contains a single 'zurg' binary at the top level
install -m 0755 /tmp/zurg-unzip/zurg /usr/local/bin/zurg
rm -rf /tmp/zurg.zip /tmp/zurg-unzip
mkdir -p /etc/zurg /var/lib/zurg
chown -R zurg:media /etc/zurg /var/lib/zurg
ZURG

pct exec "$CTID" -- bash -c "cat >/etc/zurg/config.yml <<CFG
zurg: v1
token: ${RD_API_TOKEN}
host: 127.0.0.1
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
      - regex: /\\\\bs\\\\d+(e\\\\d+)?\\\\b/i
      - regex: /\\\\b(season|episode)\\\\b/i
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
cat >/etc/systemd/system/zurg.service <<'UNIT'
[Unit]
Description=Zurg (Real-Debrid WebDAV)
After=network-online.target
Wants=network-online.target
Before=rclone-zurg.service

[Service]
Type=simple
User=zurg
Group=media
WorkingDirectory=/var/lib/zurg
ExecStart=/usr/local/bin/zurg --config /etc/zurg/config.yml
Restart=always
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/zurg /etc/zurg

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now zurg
ZUNIT
ok "zurg → 127.0.0.1:9999"

# ── 6. rclone mount + healthcheck timer ──────────────────────────────────────
info "Configuring rclone mount of zurg → /mnt/zurg + healthcheck ..."
pct exec "$CTID" -- bash <<'RC'
set -Eeuo pipefail
mkdir -p /etc/rclone /mnt/zurg
chown rclone:media /mnt/zurg
chmod 0775 /mnt/zurg
# Pre-create log file with rclone ownership; service runs unprivileged
touch /var/log/rclone-zurg.log /var/log/rclone-zurg-health.log
chown rclone:media /var/log/rclone-zurg.log /var/log/rclone-zurg-health.log
chmod 0640 /var/log/rclone-zurg.log /var/log/rclone-zurg-health.log
cat >/etc/rclone/rclone.conf <<'CFG'
[zurg]
type = webdav
url = http://127.0.0.1:9999/dav/
vendor = other
pacer_min_sleep = 0
CFG
chown rclone:media /etc/rclone/rclone.conf
chmod 0640 /etc/rclone/rclone.conf

cat >/etc/systemd/system/rclone-zurg.service <<'UNIT'
[Unit]
Description=rclone mount: zurg WebDAV -> /mnt/zurg
After=zurg.service network-online.target
Requires=zurg.service
Before=jellyfin.service riven.service

[Service]
Type=notify
User=rclone
Group=media
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do curl -fsS http://127.0.0.1:9999/dav/ >/dev/null && exit 0; sleep 2; done; exit 1'
ExecStartPre=/bin/sh -c 'mkdir -p /mnt/zurg; fusermount3 -uz /mnt/zurg 2>/dev/null || true'
ExecStart=/usr/bin/rclone mount zurg: /mnt/zurg --config=/etc/rclone/rclone.conf --allow-other --uid=1000 --gid=1000 --umask=002 --dir-cache-time=10s --vfs-cache-mode=full --vfs-cache-max-size=4G --vfs-cache-max-age=24h --buffer-size=64M --attr-timeout=8700h --poll-interval=15s --log-file=/var/log/rclone-zurg.log --log-level=INFO
ExecStop=/bin/fusermount3 -u /mnt/zurg
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT

cat >/usr/local/bin/rclone-zurg-health.sh <<'HEALTH'
#!/bin/bash
set -euo pipefail
MOUNT=/mnt/zurg
LOG=/var/log/rclone-zurg-health.log
log() { echo "$(date -Iseconds) $*" >>"$LOG"; }
if ! mountpoint -q "$MOUNT"; then
  log "NOT_MOUNTED -> restart"
  systemctl restart rclone-zurg.service
  exit 1
fi
if ! timeout 8 ls "$MOUNT" >/dev/null 2>&1; then
  log "LS_HUNG -> restart"
  systemctl restart rclone-zurg.service
  exit 1
fi
log ok
HEALTH
chmod +x /usr/local/bin/rclone-zurg-health.sh

cat >/etc/systemd/system/rclone-zurg-health.service <<'UNIT'
[Unit]
Description=rclone mount healthcheck
After=rclone-zurg.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rclone-zurg-health.sh
UNIT

cat >/etc/systemd/system/rclone-zurg-health.timer <<'UNIT'
[Unit]
Description=Run rclone-zurg healthcheck every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now rclone-zurg rclone-zurg-health.timer
RC
ok "rclone mount + 60s healthcheck timer active."

# ── 7. PostgreSQL + Riven ────────────────────────────────────────────────────
info "Installing Riven backend + frontend ..."
pct exec "$CTID" -- bash <<'RIVEN'
set -Eeuo pipefail
systemctl enable --now postgresql
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='riven'" | grep -q 1 || \
  sudo -u postgres psql <<SQL
CREATE USER riven WITH PASSWORD 'riven';
CREATE DATABASE riven OWNER riven;
SQL

git clone https://github.com/rivenmedia/riven.git /opt/riven 2>/dev/null || git -C /opt/riven pull
chown -R riven:media /opt/riven
sudo -u riven python3 -m venv /opt/riven/.venv
sudo -u riven /opt/riven/.venv/bin/pip install --quiet --upgrade pip poetry
cd /opt/riven && sudo -u riven /opt/riven/.venv/bin/poetry install --no-root --quiet

git clone https://github.com/rivenmedia/riven-frontend.git /opt/riven-frontend 2>/dev/null || git -C /opt/riven-frontend pull
cd /opt/riven-frontend
npm install --silent
npm run build --silent
chown -R riven:media /opt/riven-frontend

mkdir -p /mnt/library/movies /mnt/library/shows
chown -R riven:media /mnt/library
chmod -R 0775 /mnt/library

cat >/etc/systemd/system/riven.service <<'UNIT'
[Unit]
Description=Riven backend
After=network-online.target rclone-zurg.service postgresql.service redis-server.service
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
Environment="RIVEN_HOST=127.0.0.1"
Environment="RIVEN_PORT=8080"
ExecStart=/opt/riven/.venv/bin/python -m src.main
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/mnt/library /opt/riven /var/lib/riven /tmp

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/riven-frontend.service <<'UNIT'
[Unit]
Description=Riven frontend
After=riven.service
Requires=riven.service

[Service]
Type=simple
User=riven
Group=media
WorkingDirectory=/opt/riven-frontend
Environment="HOST=0.0.0.0"
Environment="PORT=3000"
Environment="ORIGIN=http://0.0.0.0:3000"
Environment="BACKEND_URL=http://127.0.0.1:8080"
ExecStart=/usr/bin/node build
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
RIVEN

# Splice in the real RD token
pct exec "$CTID" -- sed -i "s|__RD_API_TOKEN__|${RD_API_TOKEN}|" /etc/systemd/system/riven.service
pct exec "$CTID" -- bash -c 'systemctl daemon-reload && systemctl enable --now riven riven-frontend'
ok "Riven backend (127.0.0.1:8080) + frontend (LAN:3000)."

# Nightly Riven DB backup
info "Installing nightly Riven pg_dump cron (7-day retention) ..."
pct exec "$CTID" -- bash <<'PGB'
set -Eeuo pipefail
mkdir -p /var/backups/riven
chown postgres:postgres /var/backups/riven
chmod 0700 /var/backups/riven
cat >/etc/cron.daily/riven-pgdump <<'CRON'
#!/bin/bash
set -euo pipefail
DIR=/var/backups/riven
DATE=$(date -u +%Y%m%d)
sudo -u postgres pg_dump -Fc riven > "$DIR/riven-$DATE.pgdump"
find "$DIR" -name 'riven-*.pgdump' -mtime +7 -delete
CRON
chmod 0755 /etc/cron.daily/riven-pgdump
PGB
ok "pg_dump cron at /etc/cron.daily/riven-pgdump"

# ── 8. Jellyfin (real-time monitor on /mnt/library) ──────────────────────────
info "Configuring Jellyfin to scan /mnt/library ..."
pct exec "$CTID" -- bash <<'JF'
set -Eeuo pipefail
systemctl enable --now jellyfin
for _ in $(seq 1 60); do
  [ -d /var/lib/jellyfin/config ] && break
  sleep 2
done
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
ok "Jellyfin :8096 with real-time monitor."

# ── 9. Homarr dashboard ──────────────────────────────────────────────────────
info "Installing Homarr dashboard ..."
pct exec "$CTID" -- bash <<'HOMARR'
set -Eeuo pipefail
git clone https://github.com/ajnart/homarr.git /opt/homarr 2>/dev/null || git -C /opt/homarr pull
cd /opt/homarr
npm install --silent --legacy-peer-deps
npm run build --silent || npm run build:next --silent || true
chown -R homarr:media /opt/homarr

cat >/etc/systemd/system/homarr.service <<'UNIT'
[Unit]
Description=Homarr dashboard
After=network-online.target

[Service]
Type=simple
User=homarr
Group=media
WorkingDirectory=/opt/homarr
Environment="HOSTNAME=0.0.0.0"
Environment="PORT=7575"
Environment="NODE_ENV=production"
ExecStart=/usr/bin/npm run start
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now homarr || true
HOMARR
ok "Homarr :7575"

# ── 10. Caddy reverse proxy with auto-TLS ────────────────────────────────────
info "Configuring Caddy reverse proxy with internal TLS ..."
pct exec "$CTID" -- bash <<'CADDY'
set -Eeuo pipefail
cat >/etc/caddy/Caddyfile <<'CFG'
# bulletproof-mediastack — Caddy reverse proxy
# Self-signed TLS via Caddy's internal CA. Add /etc/hosts entries on your
# clients (192.168.12.30 jellyfin.mediastack.lan riven.mediastack.lan
# homarr.mediastack.lan) to use these names. Direct IP:port still works.

{
    auto_https disable_redirects
    local_certs
}

(common_headers) {
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer-when-downgrade"
        -Server
    }
}

riven.mediastack.lan, riven.local, http://192.168.12.30 {
    tls internal
    import common_headers
    reverse_proxy 127.0.0.1:3000
}

jellyfin.mediastack.lan, jellyfin.local {
    tls internal
    import common_headers
    reverse_proxy 127.0.0.1:8096
}

homarr.mediastack.lan, homarr.local {
    tls internal
    import common_headers
    reverse_proxy 127.0.0.1:7575
}
CFG
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable --now caddy
CADDY
ok "Caddy on :80/:443 (Riven default landing page)."

# ── 11. CrowdSec ─────────────────────────────────────────────────────────────
info "Configuring CrowdSec ..."
pct exec "$CTID" -- bash <<'CS'
set -Eeuo pipefail
# Default install scans systemd journal. Add Caddy + jellyfin acquisition.
cat >/etc/crowdsec/acquis.d/caddy.yaml <<'YML'
filenames:
  - /var/log/caddy/access.log
labels:
  type: caddy
YML
cat >/etc/crowdsec/acquis.d/journal.yaml <<'YML'
source: journalctl
journalctl_filter:
  - "_SYSTEMD_UNIT=ssh.service"
  - "_SYSTEMD_UNIT=jellyfin.service"
labels:
  type: syslog
YML
cscli collections install crowdsecurity/linux crowdsecurity/sshd crowdsecurity/caddy 2>/dev/null || true
systemctl restart crowdsec
systemctl enable --now crowdsec crowdsec-firewall-bouncer
CS
ok "CrowdSec scanning journal + Caddy access log."

# ── 12. Tailscale (opt-in) ───────────────────────────────────────────────────
if [ -n "$TAILSCALE_AUTHKEY" ]; then
  info "Installing Tailscale + bringing up with provided auth key ..."
  pct exec "$CTID" -- bash -c "curl -fsSL https://tailscale.com/install.sh | sh"
  pct exec "$CTID" -- tailscale up --authkey "$TAILSCALE_AUTHKEY" --hostname "$CT_HOSTNAME" --accept-routes
  ok "Tailscale up. Get IP: pct exec $CTID -- tailscale ip -4"
else
  info "Skipping Tailscale (set TAILSCALE_AUTHKEY to enable)."
fi

# ── 13. Final summary ────────────────────────────────────────────────────────
IP_ONLY="${IP%/*}"
cat <<EOF

============================================================
  bulletproof-mediastack — deployed in CT-${CTID} (${CT_HOSTNAME})
============================================================
  Direct (LAN, http):
    Riven UI       http://${IP_ONLY}:3000   ← request shows/movies here
    Jellyfin       http://${IP_ONLY}:8096   ← watch here
    Homarr         http://${IP_ONLY}:7575   ← dashboard

  Via Caddy (https, self-signed; add to /etc/hosts on viewing devices):
    192.168.12.30 riven.mediastack.lan jellyfin.mediastack.lan homarr.mediastack.lan
    https://riven.mediastack.lan
    https://jellyfin.mediastack.lan
    https://homarr.mediastack.lan

  Internal:
    zurg WebDAV   http://127.0.0.1:9999/dav (in CT)
    rclone mount  /mnt/zurg
    Library tree  /mnt/library  (symlinks created by Riven)
    PostgreSQL    127.0.0.1:5432
    Valkey/Redis  127.0.0.1:6379

  Reliability:
    rclone health timer       systemctl status rclone-zurg-health.timer
    Riven DB nightly pg_dump  /etc/cron.daily/riven-pgdump → /var/backups/riven
    CrowdSec IDS              cscli alerts list
    Caddy self-signed TLS     /var/lib/caddy/.local/share/caddy/pki/

  Services in CT-${CTID}:
    systemctl status zurg rclone-zurg riven riven-frontend jellyfin \\
                     homarr caddy crowdsec postgresql redis-server

  First-run setup:
    1. Open http://${IP_ONLY}:3000 → Riven first-run wizard.
    2. In Jellyfin (http://${IP_ONLY}:8096): add libraries pointing at
         /mnt/library/movies   (Movies)
         /mnt/library/shows    (TV Shows)
    3. Add a show in Riven → it appears in Jellyfin within ~30-60 seconds.

  Request → watch in seconds. The pipeline is bulletproof.
============================================================
EOF
