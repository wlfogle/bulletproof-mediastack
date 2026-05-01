#!/usr/bin/env bash
# =============================================================================
# bulletproof-mediastack — single-script native deploy
#
# Architecture (verified against rivenmedia/riven upstream Dockerfile + entrypoint
# + pyproject.toml + .env.example, rivenmedia/riven-frontend Dockerfile):
#
#   CT-300 (privileged Proxmox LXC, Debian 12)
#   ├── PostgreSQL 15           — db=riven, user=postgres, pw=postgres   :5432
#   ├── Riven backend           — Python 3.13 (uv) + built-in FUSE VFS   :8080
#   │      └── mounts /mount via RivenVFS (replaces zurg+rclone entirely)
#   ├── Riven frontend          — SvelteKit (Node 24 + pnpm)             :3000
#   ├── Jellyfin                — reads /mount, real-time monitor on     :8096
#   ├── Caddy                   — reverse proxy, internal TLS            :80/:443
#   ├── CrowdSec                — host IDS scanning systemd journal
#   └── Tailscale (opt-in)      — set TAILSCALE_AUTHKEY to enable
#
# Everything native systemd. No Docker. No Podman. No zurg. No rclone-mount.
#
# REQUIREMENTS (.env or env):
#   RD_API_TOKEN          Real-Debrid API token
#   TZ                    timezone, default America/New_York
#   TAILSCALE_AUTHKEY     optional; enables Tailscale on this CT
#
# Run on Proxmox host (Tiamat) as root:
#   bash /opt/bulletproof-mediastack/scripts/deploy.sh
#
# Env overrides:
#   CTID=300, CT_HOSTNAME=mediastack, IP=192.168.12.30/24,
#   GATEWAY=192.168.12.1, STORAGE=local-ssd, ROOTFS_GB=24, RAM_MB=8192,
#   CORES=6, FORCE_RECREATE=0
# =============================================================================
set -Eeuo pipefail

CTID="${CTID:-300}"
CT_HOSTNAME="${CT_HOSTNAME:-mediastack}"
IP="${IP:-192.168.12.30/24}"
GATEWAY="${GATEWAY:-192.168.12.1}"
STORAGE="${STORAGE:-local-ssd}"
ROOTFS_GB="${ROOTFS_GB:-24}"
RAM_MB="${RAM_MB:-8192}"
CORES="${CORES:-6}"
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst}"
TZ="${TZ:-America/New_York}"
DNS="${DNS:-8.8.8.8 1.1.1.1}"
BRIDGE="${BRIDGE:-vmbr0}"
FORCE_RECREATE="${FORCE_RECREATE:-0}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ -r "${SCRIPT_DIR}/../.env" ] && { set -a; . "${SCRIPT_DIR}/../.env"; set +a; }

: "${RD_API_TOKEN:?RD_API_TOKEN required (real-debrid.com/apitoken). Put it in .env}"

info() { printf '\033[1;36m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1;35m── %s ──\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { err "Must run as root on Proxmox host."; exit 1; }
command -v pct >/dev/null 2>&1 || { err "pct not found. Run on a Proxmox host."; exit 1; }

# Generate a stable 32-char API key (idempotent; reused on re-run)
API_KEY_FILE="/etc/bulletproof-mediastack-api-key"
if [ ! -s "$API_KEY_FILE" ]; then
  head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32 >"$API_KEY_FILE"
  chmod 0600 "$API_KEY_FILE"
fi
RIVEN_API_KEY=$(cat "$API_KEY_FILE")

step "bulletproof-mediastack → CT-${CTID} (${CT_HOSTNAME})"

# ── 0. Template ──────────────────────────────────────────────────────────────
if ! pveam list local 2>/dev/null | grep -q 'debian-12-standard'; then
  info "Downloading Debian 12 template ..."
  pveam update >/dev/null 2>&1 || true
  pveam download local debian-12-standard_12.12-1_amd64.tar.zst >/dev/null
fi

# ── 1. Create CT (privileged) ────────────────────────────────────────────────
if [ "$FORCE_RECREATE" = "1" ] && pct status "$CTID" >/dev/null 2>&1; then
  info "FORCE_RECREATE=1 — destroying CT-${CTID} ..."
  pct stop "$CTID" >/dev/null 2>&1 || true
  pct unlock "$CTID" 2>/dev/null || true
  pct destroy "$CTID" --purge 1 --destroy-unreferenced-disks 1 >/dev/null
fi

if pct status "$CTID" >/dev/null 2>&1; then
  info "CT-${CTID} exists — reusing."
else
  info "Creating privileged CT-${CTID} (${CORES}c/${RAM_MB}M/${ROOTFS_GB}G) on ${STORAGE} ..."
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" --memory "$RAM_MB" --swap "$((RAM_MB/2))" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY},type=veth" \
    --nameserver "$DNS" \
    --storage "$STORAGE" --rootfs "${STORAGE}:${ROOTFS_GB}" \
    --unprivileged 0 \
    --features "nesting=1,keyctl=1,fuse=1" \
    --onboot 1 --start 0 >/dev/null
  ok "CT-${CTID} created."
fi

# ── 2. LXC config: /dev/fuse, /dev/dri (VAAPI), /dev/net/tun (Tailscale) ────
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
add_line "lxc.cap.drop:"

# ── 3. Start CT and wait for network ─────────────────────────────────────────
if [ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]; then
  pct start "$CTID" >/dev/null
fi
for i in $(seq 1 90); do
  pct exec "$CTID" -- true 2>/dev/null && break
  sleep 1
done
pct exec "$CTID" -- true 2>/dev/null || { err "CT-${CTID} did not come up"; exit 1; }
# Wait for DNS to resolve (network propagation can take a moment after start)
for i in $(seq 1 60); do
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 2
done
ok "CT-${CTID} is up with networking."

# ── 4. Bootstrap CT: apt repos + base packages + service users + FUSE ────────
info "Bootstrapping packages and APT repos ..."
pct exec "$CTID" -- env RD_API_TOKEN="$RD_API_TOKEN" RIVEN_API_KEY="$RIVEN_API_KEY" TZ="$TZ" bash <<'BOOT'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

# Retry apt-get update up to 3x in case a mirror is briefly slow
for i in 1 2 3; do apt-get update -qq && break || sleep 5; done

# Riven backend build deps (mirror upstream Alpine deps to Debian) +
# runtime deps (libpq5, libcurl4, ffmpeg, fuse3, libcap2-bin for setcap) +
# common utilities. NodeSource installs Node24 -> "nodejs" (includes npm).
apt-get install -y --no-install-recommends -qq \
  ca-certificates curl wget gnupg jq lsb-release apt-transport-https \
  python3 python3-venv python3-dev python3-pip \
  build-essential pkg-config libffi-dev libssl-dev \
  libcurl4-openssl-dev libcurl4 libpq5 libpq-dev libfuse3-dev fuse3 libcap2-bin \
  ffmpeg unzip git sqlite3 \
  postgresql postgresql-contrib postgresql-client \
  redis-server redis-tools \
  tzdata cron \
  debian-keyring debian-archive-keyring

# Verify outbound network reaches services we depend on
for url in https://api.real-debrid.com https://github.com https://repo.jellyfin.org https://deb.nodesource.com; do
  curl -fsS --max-time 10 "$url" >/dev/null || { echo "ERR: cannot reach $url"; exit 1; }
done

install -d /usr/share/keyrings /etc/apt/sources.list.d

# Jellyfin repo (idempotent)
rm -f /usr/share/keyrings/jellyfin.gpg
curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
  | gpg --batch --yes --dearmor -o /usr/share/keyrings/jellyfin.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/jellyfin.gpg] https://repo.jellyfin.org/master/debian bookworm main" \
  >/etc/apt/sources.list.d/jellyfin.list

# Caddy repo (Cloudsmith)
rm -f /usr/share/keyrings/caddy.gpg
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
  | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy.gpg
echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
  >/etc/apt/sources.list.d/caddy.list

# NodeSource Node 24 (matches rivenmedia/riven-frontend Dockerfile)
rm -f /usr/share/keyrings/nodesource.gpg
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --batch --yes --dearmor -o /usr/share/keyrings/nodesource.gpg
echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
  >/etc/apt/sources.list.d/nodesource.list

# CrowdSec repo (their bootstrap script just adds the apt repo)
curl -fsSL https://install.crowdsec.net | bash

apt-get update -qq
apt-get install -y --no-install-recommends -qq \
  jellyfin jellyfin-ffmpeg7 \
  caddy \
  nodejs \
  crowdsec crowdsec-firewall-bouncer-iptables

# Verify Node 24 (frontend's package.json declares @types/node ^25, build needs >=20)
NODE_MAJOR=$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
[ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -ge 20 ] || { echo "ERR: Node >=20 required, got: $(node -v 2>&1)"; exit 1; }
echo "Node $(node -v), npm $(npm -v)"

# pnpm globally (frontend uses pnpm@10.28.0; their Dockerfile does npm i -g pnpm)
npm install -g pnpm@10.28.0

# uv (project Python/dep manager — Riven's pyproject is uv-native)
UV_URL=$(curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest \
  | jq -r '.assets[] | select(.name=="uv-x86_64-unknown-linux-gnu.tar.gz") | .browser_download_url' | head -1)
[ -n "$UV_URL" ] || { echo "ERR: uv release URL empty"; exit 1; }
curl -fsSL "$UV_URL" -o /tmp/uv.tar.gz
tar -xzf /tmp/uv.tar.gz -C /tmp
install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv
install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/uvx 2>/dev/null || true
rm -rf /tmp/uv.tar.gz /tmp/uv-x86_64-unknown-linux-gnu

# Service users (riven runs as 1000:1000 to match Jellyfin reading /mount)
getent group media >/dev/null || groupadd -g 1000 media
id -u riven >/dev/null 2>&1 || useradd -r -m -d /var/lib/riven -s /bin/bash -u 1000 -g 1000 riven
usermod -aG media jellyfin

# Jellyfin VAAPI groups
groupadd -g 993 render 2>/dev/null || groupmod -g 993 render
groupadd -g 44  video  2>/dev/null || groupmod -g 44  video
usermod -aG video,render jellyfin

# FUSE: allow non-root with --allow-other
sed -i 's/^#\s*user_allow_other/user_allow_other/' /etc/fuse.conf
grep -q '^user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >>/etc/fuse.conf

# fusermount3 setuid (allows non-root user-space mount/unmount)
chmod u+s /usr/bin/fusermount3 2>/dev/null || true

# Redis: localhost only, modest cache
sed -i 's/^bind .*/bind 127.0.0.1 -::1/' /etc/redis/redis.conf
sed -i 's/^# *maxmemory .*/maxmemory 256mb/' /etc/redis/redis.conf
sed -i 's/^# *maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
systemctl enable --now redis-server

# Allow root inside CT to operate on git repos owned by service users
git config --system --add safe.directory '*'
BOOT
ok "Base packages, repos, users, FUSE, Redis ready."

# ── 5. PostgreSQL: db=riven, user=postgres with password ─────────────────────
info "Configuring PostgreSQL ..."
pct exec "$CTID" -- bash <<'PG'
set -Eeuo pipefail
systemctl enable --now postgresql

# Set postgres role password (default Debian peer-only auth has no password)
runuser -u postgres -- psql -tAc "ALTER USER postgres WITH PASSWORD 'postgres';" >/dev/null

# Create riven DB if missing
runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='riven'" \
  | grep -q 1 || runuser -u postgres -- psql -tAc "CREATE DATABASE riven OWNER postgres;" >/dev/null

# Verify TCP-localhost auth works (matches Riven's DSN)
PGPASSWORD=postgres psql -h 127.0.0.1 -U postgres -d riven -tAc 'SELECT 1' >/dev/null
PG
ok "PostgreSQL ready (db=riven, user=postgres@127.0.0.1)."

# ── 6. Riven backend ─────────────────────────────────────────────────────────
info "Installing Riven backend (Python 3.13 via uv, native FUSE VFS) ..."
pct exec "$CTID" -- bash <<'RIVEN_BACKEND'
set -Eeuo pipefail

git -C /opt/riven pull 2>/dev/null \
  || git clone https://github.com/rivenmedia/riven.git /opt/riven
chown -R riven:media /opt/riven

# Install Python 3.13 + venv as the riven user (uv stores under its $HOME/.local)
runuser -u riven -- bash -c '
  set -Eeuo pipefail
  export UV_PYTHON_INSTALL_DIR=/var/lib/riven/.uv-python
  export UV_CACHE_DIR=/var/lib/riven/.uv-cache
  cd /opt/riven
  /usr/local/bin/uv python install 3.13
  rm -rf .venv
  /usr/local/bin/uv venv --python 3.13 .venv
  # Riven pyproject is uv-native (has [tool.uv]). uv sync handles everything,
  # uses uv.lock if present (--frozen). --no-dev skips dev/test groups.
  if [ -f uv.lock ]; then
    /usr/local/bin/uv sync --no-dev --frozen
  else
    /usr/local/bin/uv sync --no-dev
  fi
'

# RivenVFS uses pyfuse3 which needs CAP_SYS_ADMIN to mount FUSE.
# setcap on the venv python binary (mirrors upstream Dockerfile).
PY_BIN=$(readlink -f /opt/riven/.venv/bin/python)
setcap cap_sys_admin+ep "$PY_BIN"
getcap "$PY_BIN" | grep -q cap_sys_admin || { echo "ERR: setcap failed on $PY_BIN"; exit 1; }

# Mount point for RivenVFS
mkdir -p /mount
chown riven:media /mount
chmod 0775 /mount
RIVEN_BACKEND
ok "Riven backend installed."

# Riven systemd unit (env-driven via RIVEN_FORCE_ENV=true)
pct exec "$CTID" -- bash -c "cat >/etc/systemd/system/riven.service <<UNIT
[Unit]
Description=Riven backend (request UI + RivenVFS)
After=network-online.target postgresql.service redis-server.service
Requires=postgresql.service

[Service]
Type=simple
User=riven
Group=media
WorkingDirectory=/opt/riven
Environment=PATH=/opt/riven/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=/var/lib/riven
Environment=UV_PYTHON_INSTALL_DIR=/var/lib/riven/.uv-python
Environment=UV_CACHE_DIR=/var/lib/riven/.uv-cache
Environment=RIVEN_FORCE_ENV=true
Environment=API_KEY=${RIVEN_API_KEY}
Environment=RIVEN_DATABASE_HOST=postgresql+psycopg2://postgres:postgres@127.0.0.1/riven
Environment=RIVEN_FILESYSTEM_MOUNT_PATH=/mount
Environment=RIVEN_LIBRARY_PATH=/mount
Environment=RIVEN_DOWNLOADERS_REAL_DEBRID_ENABLED=true
Environment=RIVEN_DOWNLOADERS_REAL_DEBRID_API_KEY=${RD_API_TOKEN}
Environment=RIVEN_SCRAPING_TORRENTIO_ENABLED=true
Environment=RIVEN_JELLYFIN_ENABLED=true
Environment=RIVEN_JELLYFIN_URL=http://127.0.0.1:8096
ExecStart=/opt/riven/.venv/bin/python src/main.py
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
# AmbientCapabilities preserved when User= drops privileges
AmbientCapabilities=CAP_SYS_ADMIN
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_NET_BIND_SERVICE CAP_DAC_OVERRIDE CAP_CHOWN CAP_SETUID CAP_SETGID

[Install]
WantedBy=multi-user.target
UNIT"

# ── 7. Riven frontend (SvelteKit + Node + pnpm) ──────────────────────────────
info "Installing Riven frontend (Node 24 + pnpm) ..."
pct exec "$CTID" -- bash <<'RIVEN_FRONTEND'
set -Eeuo pipefail

git -C /opt/riven-frontend pull 2>/dev/null \
  || git clone https://github.com/rivenmedia/riven-frontend.git /opt/riven-frontend
chown -R riven:media /opt/riven-frontend

runuser -u riven -- bash -c '
  set -Eeuo pipefail
  cd /opt/riven-frontend
  # pnpm needs a writable HOME for its store
  export HOME=/var/lib/riven
  pnpm install --frozen-lockfile=false
  pnpm run build
  pnpm prune --prod
'
RIVEN_FRONTEND
ok "Riven frontend built."

pct exec "$CTID" -- bash -c "cat >/etc/systemd/system/riven-frontend.service <<UNIT
[Unit]
Description=Riven frontend (SvelteKit)
After=riven.service
Requires=riven.service

[Service]
Type=simple
User=riven
Group=media
WorkingDirectory=/opt/riven-frontend
Environment=HOME=/var/lib/riven
Environment=NODE_ENV=production
Environment=HOST=0.0.0.0
Environment=PORT=3000
Environment=ORIGIN=http://${IP%/*}:3000
Environment=BACKEND_URL=http://127.0.0.1:8080
ExecStart=/usr/bin/node /opt/riven-frontend/build
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT"

# ── 8. Jellyfin: enable real-time monitor (after first start writes config) ──
info "Configuring Jellyfin (real-time monitor on /mount) ..."
pct exec "$CTID" -- bash <<'JF'
set -Eeuo pipefail
systemctl enable --now jellyfin
# Wait for first-run to write its libraries dir
for i in $(seq 1 90); do
  [ -d /var/lib/jellyfin/config ] && break
  sleep 2
done
LIB_DIR=/var/lib/jellyfin/config/libraries
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
ok "Jellyfin :8096 configured (real-time monitor)."

# ── 9. Caddy reverse proxy (self-signed TLS via internal CA) ─────────────────
info "Configuring Caddy reverse proxy ..."
pct exec "$CTID" -- bash -c "cat >/etc/caddy/Caddyfile <<'CFG'
{
    auto_https disable_redirects
    local_certs
}

(headers) {
    header {
        Strict-Transport-Security \"max-age=31536000\"
        X-Content-Type-Options \"nosniff\"
        Referrer-Policy \"no-referrer-when-downgrade\"
        -Server
    }
}

riven.mediastack.lan, riven.local {
    tls internal
    import headers
    reverse_proxy 127.0.0.1:3000
}

jellyfin.mediastack.lan, jellyfin.local {
    tls internal
    import headers
    reverse_proxy 127.0.0.1:8096
}

http://${IP%/*} {
    redir / /riven/ permanent
    handle_path /riven/* {
        reverse_proxy 127.0.0.1:3000
    }
    handle_path /jellyfin/* {
        reverse_proxy 127.0.0.1:8096
    }
}
CFG
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable --now caddy"
ok "Caddy :80/:443 ready."

# ── 10. CrowdSec ─────────────────────────────────────────────────────────────
info "Configuring CrowdSec ..."
pct exec "$CTID" -- bash <<'CS'
set -Eeuo pipefail
mkdir -p /etc/crowdsec/acquis.d
cat >/etc/crowdsec/acquis.d/journal.yaml <<'YML'
source: journalctl
journalctl_filter:
  - "_SYSTEMD_UNIT=ssh.service"
  - "_SYSTEMD_UNIT=jellyfin.service"
  - "_SYSTEMD_UNIT=riven.service"
labels:
  type: syslog
YML
cat >/etc/crowdsec/acquis.d/caddy.yaml <<'YML'
filenames:
  - /var/log/caddy/access.log
labels:
  type: caddy
YML
cscli collections install crowdsecurity/linux crowdsecurity/sshd crowdsecurity/caddy 2>&1 | tail -5
systemctl restart crowdsec
systemctl enable --now crowdsec crowdsec-firewall-bouncer
CS
ok "CrowdSec scanning journal + Caddy access log."

# ── 11. Tailscale (opt-in) ───────────────────────────────────────────────────
if [ -n "$TAILSCALE_AUTHKEY" ]; then
  info "Joining Tailscale tailnet ..."
  pct exec "$CTID" -- bash -c "curl -fsSL https://tailscale.com/install.sh | sh"
  pct exec "$CTID" -- tailscale up --authkey "$TAILSCALE_AUTHKEY" --hostname "$CT_HOSTNAME" --accept-routes
  ok "Tailscale up. IP: $(pct exec "$CTID" -- tailscale ip -4 2>/dev/null | head -1)"
else
  info "Skipping Tailscale (set TAILSCALE_AUTHKEY to enable)."
fi

# ── 12. Enable Riven services + verify everything is alive ──────────────────
info "Starting Riven backend + frontend ..."
pct exec "$CTID" -- bash -c '
systemctl daemon-reload
systemctl enable --now riven riven-frontend
'

step "Verifying all services are active"
SERVICES="postgresql redis-server jellyfin caddy crowdsec crowdsec-firewall-bouncer riven riven-frontend"
[ -n "$TAILSCALE_AUTHKEY" ] && SERVICES="$SERVICES tailscaled"
ALL_OK=1
sleep 5  # give services a moment to settle
for svc in $SERVICES; do
  state=$(pct exec "$CTID" -- systemctl is-active "$svc" 2>&1)
  if [ "$state" = "active" ]; then
    ok "  $svc: active"
  else
    err "  $svc: $state"
    pct exec "$CTID" -- journalctl -xeu "$svc" --no-pager 2>&1 | tail -8 | sed 's/^/    | /'
    ALL_OK=0
  fi
done

# ── 13. Summary ──────────────────────────────────────────────────────────────
IP_ONLY="${IP%/*}"
cat <<EOF

============================================================
  bulletproof-mediastack — CT-${CTID} (${CT_HOSTNAME})
============================================================
  Direct (LAN, http):
    Riven UI       http://${IP_ONLY}:3000   ← request shows/movies here
    Jellyfin       http://${IP_ONLY}:8096   ← watch here
    Riven API      http://${IP_ONLY}:8080   (used internally by frontend)

  Caddy (https, self-signed; add to /etc/hosts on viewing devices):
    ${IP_ONLY} riven.mediastack.lan jellyfin.mediastack.lan
    https://riven.mediastack.lan
    https://jellyfin.mediastack.lan

  Internal:
    PostgreSQL    127.0.0.1:5432  (db=riven user=postgres pw=postgres)
    Redis/Valkey  127.0.0.1:6379
    Riven VFS     /mount (FUSE — provided by Riven backend itself)

  Riven API key: ${RIVEN_API_KEY}
                 (also stored at /etc/bulletproof-mediastack-api-key on Tiamat)

  Logs:
    pct exec ${CTID} -- journalctl -fu riven
    pct exec ${CTID} -- journalctl -fu riven-frontend
    pct exec ${CTID} -- journalctl -fu jellyfin

  First-run setup:
    1. Open http://${IP_ONLY}:3000 → finish Riven onboarding (RD token already
       configured via env). Confirm a content source (Trakt list, Mdblist) or
       just add a single show to test the chain.
    2. In Jellyfin (http://${IP_ONLY}:8096): add libraries pointing at
         /mount/movies   (Movies)
         /mount/shows    (TV Shows)
       (Real-time monitor is already enabled.)
    3. Add a show in Riven → it appears in /mount via FUSE → Jellyfin picks
       it up within ~30-60 seconds.

EOF
if [ "$ALL_OK" -eq 1 ]; then
  ok "Pipeline is bulletproof. Request → watch in seconds."
else
  err "One or more services failed to start. See journal output above."
  exit 1
fi
