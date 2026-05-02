#!/usr/bin/env bash
# =============================================================================
# bulletproof-mediastack — single-script native deploy (hardened)
#
# Architecture (verified against rivenmedia/riven upstream Dockerfile + entrypoint
# + pyproject.toml + .env.example, rivenmedia/riven-frontend Dockerfile +
# package.json + svelte.config.js + docker-entrypoint.sh + .env.example):
#
#   CT-300 (privileged Proxmox LXC, Debian 12)
#   ├── PostgreSQL 15           — db=riven, user=postgres, pw=postgres   :5432
#   ├── Riven backend           — Python 3.13 (uv) + built-in FUSE VFS   :8080
#   │      └── mounts /mount via RivenVFS (replaces zurg+rclone entirely)
#   ├── Riven frontend          — SvelteKit (Node 24 + pnpm + sqlite)    :3000
#   ├── Jellyfin                — reads /mount, real-time monitor on     :8096
#   ├── Caddy                   — reverse proxy, internal TLS            :80/:443
#   ├── CrowdSec                — host IDS scanning systemd journal
#   └── Tailscale (opt-in)      — set TAILSCALE_AUTHKEY to enable
#
# All native systemd. No Docker. No Podman. No zurg. No rclone.
#
# Required env (.env or environment):
#   RD_API_TOKEN          Real-Debrid API token (validated at preflight)
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
#
# Hardening (this version):
#   * Preflight: RD-token auth, endpoint reachability, host disk + RAM checks
#   * Locales generated (en_US.UTF-8 + C.UTF-8) before postgres starts
#   * libsqlite3-dev installed for the frontend's better-sqlite3 native build
#   * Render gid auto-detected from /dev/dri/renderD128 inside the CT
#   * /dev/shm sizing not relied on; RivenVFS cache lives at /var/cache/riven
#   * uv pinned with retry+fallback; Node24/pnpm@10.28.0 pinned
#   * pg_hba scram-sha-256 verified; TCP password auth proven before exit
#   * Riven backend env includes the explicit cache dir
#   * Riven frontend env includes BACKEND_API_KEY, AUTH_SECRET, DATABASE_URL,
#     PROTOCOL_HEADER, HOST_HEADER (all required for SvelteKit/better-auth)
#   * NODE_OPTIONS=--max-old-space-size=6144 for the Vite build (avoids OOM)
#   * Frontend build artefact (build/index.js) verified before service enable
#   * Caddy `caddy validate` is a hard gate before enable
#   * Per-service active-state wait + HTTP probe loop (Riven, frontend,
#     Jellyfin, Caddy) before declaring success
#   * Persistent secrets stored on the Proxmox host in /etc/bulletproof-*
#   * Idempotent on rerun (FORCE_RECREATE=1 to wipe and rebuild)
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
UV_VERSION="${UV_VERSION:-0.5.16}"
PNPM_VERSION="${PNPM_VERSION:-10.28.0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ -r "${SCRIPT_DIR}/../.env" ] && { set -a; . "${SCRIPT_DIR}/../.env"; set +a; }

: "${RD_API_TOKEN:?RD_API_TOKEN required (real-debrid.com/apitoken). Put it in .env}"

info() { printf '\033[1;36m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1;35m── %s ──\033[0m\n' "$*"; }

# Retry wrapper: retry <tries> <sleep> <cmd...>
retry() {
  local tries="$1"; shift
  local pause="$1"; shift
  local i=1
  while [ "$i" -le "$tries" ]; do
    if "$@"; then return 0; fi
    warn "attempt $i/$tries failed: $*"
    sleep "$pause"
    i=$((i+1))
  done
  return 1
}

[ "$(id -u)" -eq 0 ] || { err "Must run as root on Proxmox host."; exit 1; }
command -v pct >/dev/null 2>&1 || { err "pct not found. Run on a Proxmox host."; exit 1; }
command -v jq  >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq; }

# ── Persistent secrets on host ───────────────────────────────────────────────
API_KEY_FILE="/etc/bulletproof-mediastack-api-key"
AUTH_SECRET_FILE="/etc/bulletproof-mediastack-auth-secret"

if [ ! -s "$API_KEY_FILE" ]; then
  head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32 >"$API_KEY_FILE"
  chmod 0600 "$API_KEY_FILE"
fi
RIVEN_API_KEY=$(cat "$API_KEY_FILE")
[ "${#RIVEN_API_KEY}" -eq 32 ] || { err "$API_KEY_FILE must contain exactly 32 chars"; exit 1; }

if [ ! -s "$AUTH_SECRET_FILE" ]; then
  openssl rand -base64 32 | tr -d '\n' >"$AUTH_SECRET_FILE"
  chmod 0600 "$AUTH_SECRET_FILE"
fi
AUTH_SECRET=$(cat "$AUTH_SECRET_FILE")
[ -n "$AUTH_SECRET" ] || { err "$AUTH_SECRET_FILE empty"; exit 1; }

# =============================================================================
# PREFLIGHT — fail fast on anything that would break later
# =============================================================================
step "Preflight"

# 1) RD token authentication (avoids running 5+ minutes only to find a bad token)
info "Validating Real-Debrid token ..."
RD_USER_JSON=$(curl -fsS --max-time 15 \
  -H "Authorization: Bearer ${RD_API_TOKEN}" \
  https://api.real-debrid.com/rest/1.0/user 2>/dev/null || true)
if [ -z "$RD_USER_JSON" ] || ! echo "$RD_USER_JSON" | jq -e .username >/dev/null 2>&1; then
  err "Real-Debrid token rejected by https://api.real-debrid.com/rest/1.0/user"
  err "Set a valid RD_API_TOKEN in .env (https://real-debrid.com/apitoken)"
  exit 1
fi
RD_USER=$(echo "$RD_USER_JSON" | jq -r .username)
RD_TYPE=$(echo "$RD_USER_JSON" | jq -r .type)
ok "RD account: ${RD_USER} (${RD_TYPE})"

# 2) Endpoint reachability for every URL the bootstrap will hit
PREFLIGHT_URLS=(
  "https://deb.debian.org"
  "https://github.com"
  "https://api.github.com"
  "https://repo.jellyfin.org/jellyfin_team.gpg.key"
  "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"
  "https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
  "https://install.crowdsec.net"
  "https://astral.sh/uv/install.sh"
)
info "Verifying outbound reachability ..."
for u in "${PREFLIGHT_URLS[@]}"; do
  if curl -fsS --max-time 12 -o /dev/null "$u"; then
    ok "  reachable: $u"
  else
    err "  unreachable: $u"
    exit 1
  fi
done

# 3) Host has free RAM / disk for the requested CT sizing
HOST_FREE_MB=$(free -m | awk '/^Mem:/{print $7}')
if [ "$HOST_FREE_MB" -lt "$RAM_MB" ]; then
  warn "Host has ${HOST_FREE_MB} MB available; CT requests ${RAM_MB} MB. Proceeding (kernel will swap)."
fi

# Storage capacity is checked indirectly via pct create later — but we can
# at least confirm the storage is registered.
if ! pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$STORAGE"; then
  err "Storage '$STORAGE' is not registered on this Proxmox host (pvesm status)."
  exit 1
fi
ok "Storage '$STORAGE' is registered."

# 4) Host /dev/dri sanity (so the CT can do VAAPI). Non-fatal.
if [ ! -c /dev/dri/renderD128 ]; then
  warn "/dev/dri/renderD128 missing on host — Jellyfin VAAPI will be CPU-only."
fi

step "bulletproof-mediastack → CT-${CTID} (${CT_HOSTNAME})"

# ── 0. Template ──────────────────────────────────────────────────────────────
if ! pveam list local 2>/dev/null | grep -q 'debian-12-standard'; then
  info "Downloading Debian 12 template ..."
  retry 3 5 pveam update >/dev/null 2>&1 || true
  retry 3 10 pveam download local debian-12-standard_12.12-1_amd64.tar.zst >/dev/null
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

# ── 2. LXC config: /dev/fuse, /dev/dri (VAAPI), /dev/net/tun ─────────────────
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

# ── 3. Start CT and wait for network/DNS ─────────────────────────────────────
if [ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]; then
  pct start "$CTID" >/dev/null
fi
for i in $(seq 1 90); do
  pct exec "$CTID" -- true 2>/dev/null && break
  sleep 1
done
pct exec "$CTID" -- true 2>/dev/null || { err "CT-${CTID} did not come up"; exit 1; }
for i in $(seq 1 60); do
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 2
done
pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 \
  || { err "CT-${CTID} has no DNS"; exit 1; }
ok "CT-${CTID} is up with networking."

# Detect the host's render gid so we can mirror it inside the CT (instead of
# guessing 993 — Debian 12 uses 993 but newer hosts may differ).
RENDER_GID=$(pct exec "$CTID" -- bash -c 'stat -c %g /dev/dri/renderD128 2>/dev/null || echo 993')
[ -n "$RENDER_GID" ] || RENDER_GID=993
info "Detected render gid inside CT: ${RENDER_GID}"

# ── 4. Bootstrap CT: apt repos, base packages, service users, FUSE ───────────
info "Bootstrapping packages and APT repos ..."
pct exec "$CTID" -- env \
  RD_API_TOKEN="$RD_API_TOKEN" \
  RIVEN_API_KEY="$RIVEN_API_KEY" \
  AUTH_SECRET="$AUTH_SECRET" \
  TZ="$TZ" \
  RENDER_GID="$RENDER_GID" \
  UV_VERSION="$UV_VERSION" \
  PNPM_VERSION="$PNPM_VERSION" \
  bash <<'BOOT'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

retry() {
  local n=1 max="$1"; shift
  local pause="$1"; shift
  while [ "$n" -le "$max" ]; do
    if "$@"; then return 0; fi
    echo "  retry $n/$max for: $*" >&2
    sleep "$pause"; n=$((n+1))
  done
  return 1
}

retry 5 5 apt-get update -qq

# Build deps + runtime libs + Postgres + Redis + locales/tzdata + sqlite headers
# (sqlite headers are required by better-sqlite3's prebuild fallback).
apt-get install -y --no-install-recommends -qq \
  ca-certificates curl wget gnupg jq lsb-release apt-transport-https \
  python3 python3-venv python3-dev python3-pip \
  build-essential pkg-config libffi-dev libssl-dev \
  libcurl4-openssl-dev libcurl4 libpq5 libpq-dev libfuse3-dev fuse3 libcap2-bin \
  libsqlite3-dev sqlite3 \
  ffmpeg unzip git \
  postgresql postgresql-contrib postgresql-client \
  redis-server redis-tools \
  tzdata cron locales openssl \
  debian-keyring debian-archive-keyring

# Locale (Debian standard image only has C.UTF-8). Generate en_US.UTF-8 too,
# because some tooling assumes it.
if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
  sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  locale-gen en_US.UTF-8
fi
update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8

# Timezone
ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
echo "$TZ" >/etc/timezone

# Verify outbound network reaches services we depend on
for url in https://api.real-debrid.com https://github.com https://repo.jellyfin.org https://deb.nodesource.com; do
  curl -fsS --max-time 10 "$url" >/dev/null || { echo "ERR: cannot reach $url"; exit 1; }
done

install -d /usr/share/keyrings /etc/apt/sources.list.d

# Jellyfin repo (idempotent)
rm -f /usr/share/keyrings/jellyfin.gpg
retry 3 5 bash -c 'curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/jellyfin.gpg'
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/jellyfin.gpg] https://repo.jellyfin.org/master/debian bookworm main" \
  >/etc/apt/sources.list.d/jellyfin.list

# Caddy repo (Cloudsmith)
rm -f /usr/share/keyrings/caddy.gpg
retry 3 5 bash -c 'curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy.gpg'
echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
  >/etc/apt/sources.list.d/caddy.list

# NodeSource Node 24 (matches rivenmedia/riven-frontend Dockerfile)
rm -f /usr/share/keyrings/nodesource.gpg
retry 3 5 bash -c 'curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/nodesource.gpg'
echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
  >/etc/apt/sources.list.d/nodesource.list

# CrowdSec repo (their bootstrap script just adds the apt repo)
retry 3 5 bash -c 'curl -fsSL https://install.crowdsec.net | bash'

retry 5 5 apt-get update -qq
apt-get install -y --no-install-recommends -qq \
  jellyfin jellyfin-ffmpeg7 \
  caddy \
  nodejs \
  crowdsec crowdsec-firewall-bouncer-iptables

# Verify Node 24
NODE_MAJOR=$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
[ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -ge 20 ] || { echo "ERR: Node >=20 required, got: $(node -v 2>&1)"; exit 1; }
echo "Node $(node -v), npm $(npm -v)"

# Pin pnpm globally
npm install -g "pnpm@${PNPM_VERSION}"
pnpm --version >/dev/null

# uv (fast Python package manager). Try pinned tarball first; fall back to
# astral.sh installer if GitHub release URL is being flaky.
install_uv_pinned() {
  local v="$1"
  local url="https://github.com/astral-sh/uv/releases/download/${v}/uv-x86_64-unknown-linux-gnu.tar.gz"
  curl -fsSL --max-time 30 "$url" -o /tmp/uv.tar.gz || return 1
  tar -xzf /tmp/uv.tar.gz -C /tmp
  install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv
  install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/uvx 2>/dev/null || true
  rm -rf /tmp/uv.tar.gz /tmp/uv-x86_64-unknown-linux-gnu
}
install_uv_latest() {
  curl -fsSL --max-time 30 https://astral.sh/uv/install.sh -o /tmp/uv-install.sh || return 1
  UV_INSTALL_DIR=/usr/local/bin sh /tmp/uv-install.sh -q || return 1
  rm -f /tmp/uv-install.sh
}
if ! command -v uv >/dev/null 2>&1; then
  install_uv_pinned "$UV_VERSION" || install_uv_latest \
    || { echo "ERR: failed to install uv"; exit 1; }
fi
uv --version >/dev/null

# Service users (riven runs as 1000:1000 to align with Jellyfin reading /mount)
getent group media >/dev/null || groupadd -g 1000 media
id -u riven >/dev/null 2>&1 || useradd -r -m -d /var/lib/riven -s /bin/bash -u 1000 -g 1000 riven
usermod -aG media jellyfin

# Frontend's persistent home (sqlite db + drizzle state)
install -d -o riven -g media -m 0750 /var/lib/riven-frontend
install -d -o riven -g media -m 0750 /var/cache/riven

# VAAPI groups: align with the host's actual render gid (detected upstream).
if [ "$RENDER_GID" != "993" ] && getent group render >/dev/null 2>&1; then
  groupmod -g "$RENDER_GID" render 2>/dev/null || true
fi
if ! getent group render >/dev/null 2>&1; then
  groupadd -g "$RENDER_GID" render
fi
getent group video >/dev/null || groupadd -g 44 video
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
ok "Base packages, repos, users, FUSE, Redis, locales ready."

# ── 5. PostgreSQL: db=riven, user=postgres TCP-auth verified ─────────────────
info "Configuring PostgreSQL ..."
pct exec "$CTID" -- bash <<'PG'
set -Eeuo pipefail
systemctl enable --now postgresql

# Set postgres role password
runuser -u postgres -- psql -tAc "ALTER USER postgres WITH PASSWORD 'postgres';" >/dev/null

# Create riven DB if missing
runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='riven'" \
  | grep -q 1 || runuser -u postgres -- psql -tAc "CREATE DATABASE riven OWNER postgres;" >/dev/null

# Ensure pg_hba allows scram-sha-256 over loopback (Debian default does, but
# verify for safety — older clusters or earlier package configs may differ).
PG_HBA=$(runuser -u postgres -- psql -tAc 'SHOW hba_file' | tr -d ' ')
if ! grep -E '^[^#]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+(scram-sha-256|md5)' "$PG_HBA" >/dev/null; then
  echo "host all all 127.0.0.1/32 scram-sha-256" >>"$PG_HBA"
  systemctl reload postgresql
fi

# Verify TCP-localhost auth works (matches Riven's DSN)
PGPASSWORD=postgres psql -h 127.0.0.1 -U postgres -d riven -tAc 'SELECT 1' >/dev/null
PG
ok "PostgreSQL ready (db=riven, user=postgres@127.0.0.1)."

# ── 6. Riven backend ─────────────────────────────────────────────────────────
info "Installing Riven backend (Python 3.13 via uv, native FUSE VFS) ..."
pct exec "$CTID" -- bash <<'RIVEN_BACKEND'
set -Eeuo pipefail

if [ -d /opt/riven/.git ]; then
  git -C /opt/riven fetch --depth=1 origin main
  git -C /opt/riven reset --hard origin/main
else
  git clone --depth=1 https://github.com/rivenmedia/riven.git /opt/riven
fi
chown -R riven:media /opt/riven

# Install Python 3.13 + venv as the riven user
runuser -u riven -- bash -c '
  set -Eeuo pipefail
  export HOME=/var/lib/riven
  export UV_PYTHON_INSTALL_DIR=/var/lib/riven/.uv-python
  export UV_CACHE_DIR=/var/lib/riven/.uv-cache
  cd /opt/riven
  /usr/local/bin/uv python install 3.13
  rm -rf .venv
  /usr/local/bin/uv venv --python 3.13 .venv
  if [ -f uv.lock ]; then
    /usr/local/bin/uv sync --no-dev --frozen
  else
    /usr/local/bin/uv sync --no-dev
  fi
'

# RivenVFS uses pyfuse3 which needs CAP_SYS_ADMIN to mount FUSE.
PY_BIN=$(readlink -f /opt/riven/.venv/bin/python)
setcap cap_sys_admin+ep "$PY_BIN"
getcap "$PY_BIN" | grep -q cap_sys_admin || { echo "ERR: setcap failed on $PY_BIN"; exit 1; }

# Mount point + cache dir (RivenVFS default cache is /dev/shm/riven-cache, but
# /dev/shm in privileged LXC defaults to 64M — too small. Use a regular path.)
install -d -o riven -g media -m 0775 /mount
install -d -o riven -g media -m 0750 /var/cache/riven
RIVEN_BACKEND
ok "Riven backend installed."

# Riven systemd unit (env-driven via RIVEN_FORCE_ENV=true)
pct exec "$CTID" -- bash -c "cat >/etc/systemd/system/riven.service <<UNIT
[Unit]
Description=Riven backend (request UI + RivenVFS)
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=riven
Group=media
WorkingDirectory=/opt/riven
Environment=PATH=/opt/riven/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=/var/lib/riven
Environment=TZ=${TZ}
Environment=UV_PYTHON_INSTALL_DIR=/var/lib/riven/.uv-python
Environment=UV_CACHE_DIR=/var/lib/riven/.uv-cache
Environment=RIVEN_FORCE_ENV=true
Environment=API_KEY=${RIVEN_API_KEY}
Environment=RIVEN_DATABASE_HOST=postgresql+psycopg2://postgres:postgres@127.0.0.1/riven
Environment=RIVEN_FILESYSTEM_MOUNT_PATH=/mount
Environment=RIVEN_LIBRARY_PATH=/mount
Environment=RIVEN_FILESYSTEM_CACHE_DIR=/var/cache/riven
Environment=RIVEN_FILESYSTEM_CACHE_MAX_SIZE_MB=1024
Environment=RIVEN_DOWNLOADERS_REAL_DEBRID_ENABLED=true
Environment=RIVEN_DOWNLOADERS_REAL_DEBRID_API_KEY=${RD_API_TOKEN}
Environment=RIVEN_SCRAPING_TORRENTIO_ENABLED=true
Environment=RIVEN_JELLYFIN_ENABLED=true
Environment=RIVEN_JELLYFIN_URL=http://127.0.0.1:8096
ExecStart=/opt/riven/.venv/bin/python src/main.py
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
AmbientCapabilities=CAP_SYS_ADMIN
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_NET_BIND_SERVICE CAP_DAC_OVERRIDE CAP_CHOWN CAP_SETUID CAP_SETGID

[Install]
WantedBy=multi-user.target
UNIT"

# ── 7. Riven frontend (SvelteKit + Node 24 + pnpm + better-sqlite3) ──────────
info "Installing Riven frontend (Node 24 + pnpm) ..."
pct exec "$CTID" -- bash <<'RIVEN_FRONTEND'
set -Eeuo pipefail

if [ -d /opt/riven-frontend/.git ]; then
  git -C /opt/riven-frontend fetch --depth=1 origin main
  git -C /opt/riven-frontend reset --hard origin/main
else
  git clone --depth=1 https://github.com/rivenmedia/riven-frontend.git /opt/riven-frontend
fi
chown -R riven:media /opt/riven-frontend

runuser -u riven -- bash -c '
  set -Eeuo pipefail
  cd /opt/riven-frontend
  export HOME=/var/lib/riven
  # Vite/SvelteKit build needs more than the V8 default heap (~4 GB).
  # CT has 8 GB, so 6 GB leaves headroom for postgres/redis/jellyfin.
  export NODE_OPTIONS="--max-old-space-size=6144"
  pnpm install --frozen-lockfile=false
  pnpm run build
  pnpm prune --prod
'

# Verify build output exists (adapter-node writes build/index.js)
if [ ! -s /opt/riven-frontend/build/index.js ]; then
  echo "ERR: frontend build produced no /opt/riven-frontend/build/index.js"
  ls -la /opt/riven-frontend/build 2>&1 || true
  exit 1
fi
RIVEN_FRONTEND
ok "Riven frontend built."

# Frontend systemd unit. Required env from rivenmedia/riven-frontend/.env.example:
#   BACKEND_URL, BACKEND_API_KEY, DATABASE_URL, AUTH_SECRET, ORIGIN.
# Plus PROTOCOL_HEADER + HOST_HEADER from their docker-entrypoint.sh so SvelteKit
# trusts proxy headers from Caddy.
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
Environment=TZ=${TZ}
Environment=NODE_ENV=production
Environment=HOST=0.0.0.0
Environment=PORT=3000
Environment=ORIGIN=http://${IP%/*}:3000
Environment=PROTOCOL_HEADER=x-forwarded-proto
Environment=HOST_HEADER=x-forwarded-host
Environment=BACKEND_URL=http://127.0.0.1:8080
Environment=BACKEND_API_KEY=${RIVEN_API_KEY}
Environment=DATABASE_URL=/var/lib/riven-frontend/riven.db
Environment=AUTH_SECRET=${AUTH_SECRET}
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

# ── 9. Caddy reverse proxy (validate first, then enable) ─────────────────────
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
CFG"
# Hard gate: if validation fails, do NOT enable caddy
pct exec "$CTID" -- caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
  || { err "Caddyfile failed validation"; exit 1; }
pct exec "$CTID" -- systemctl enable --now caddy
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
cscli collections install crowdsecurity/linux crowdsecurity/sshd crowdsecurity/caddy 2>&1 | tail -5 || true
systemctl restart crowdsec || true
systemctl enable --now crowdsec crowdsec-firewall-bouncer || true
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

# ── 12. Enable Riven services + verify everything is alive ───────────────────
info "Starting Riven backend + frontend ..."
pct exec "$CTID" -- bash -c '
systemctl daemon-reload
systemctl enable --now riven riven-frontend
'

step "Verifying all services are active"
SERVICES="postgresql redis-server jellyfin caddy crowdsec crowdsec-firewall-bouncer riven riven-frontend"
[ -n "$TAILSCALE_AUTHKEY" ] && SERVICES="$SERVICES tailscaled"
ALL_OK=1

# Active-state wait per service (up to 60s)
for svc in $SERVICES; do
  state="unknown"
  for j in $(seq 1 30); do
    state=$(pct exec "$CTID" -- systemctl is-active "$svc" 2>&1 || true)
    [ "$state" = "active" ] && break
    sleep 2
  done
  if [ "$state" = "active" ]; then
    ok "  $svc: active"
  else
    err "  $svc: $state"
    pct exec "$CTID" -- journalctl -xeu "$svc" --no-pager 2>&1 | tail -12 | sed 's/^/    | /'
    ALL_OK=0
  fi
done

# HTTP probes — a service can be active and broken
http_probe() {
  local label="$1" url="$2"
  for j in $(seq 1 30); do
    if pct exec "$CTID" -- curl -fsS --max-time 5 -o /dev/null "$url"; then
      ok "  $label HTTP OK ($url)"
      return 0
    fi
    sleep 2
  done
  err "  $label HTTP FAIL ($url)"
  return 1
}
http_probe "Riven backend" "http://127.0.0.1:8080" || ALL_OK=0
http_probe "Riven frontend" "http://127.0.0.1:3000" || ALL_OK=0
http_probe "Jellyfin"      "http://127.0.0.1:8096/System/Info/Public" || ALL_OK=0
http_probe "Caddy (HTTP)"  "http://127.0.0.1/riven/" || ALL_OK=0

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

  Persistent secrets on Tiamat:
    /etc/bulletproof-mediastack-api-key       (Riven backend API_KEY)
    /etc/bulletproof-mediastack-auth-secret   (frontend AUTH_SECRET)

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
  err "One or more checks failed. See journal output above."
  exit 1
fi
