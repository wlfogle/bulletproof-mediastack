#!/usr/bin/env bash
# =============================================================================
# bahamut/migrate-to-native.sh — Docker → native systemd migration
#
# Host:       Bahamut (Raspberry Pi 4, Debian 13 trixie, aarch64)
# Before:     AdGuard Home, Vaultwarden, Caddy, wg-easy all in Docker
# After:      AdGuard Home, Vaultwarden, Caddy (with DuckDNS) as native
#             systemd services; Docker, wg-easy, and WireGuard removed.
#
# Services preserved:
#   AdGuardHome  — DNS/ad-blocking, admin :8081, DNS :53
#   Vaultwarden  — password manager, :8080 (proxied by Caddy)
#   Caddy        — TLS reverse proxy with DuckDNS DNS-01 challenge, :80/:443
#
# Services removed:
#   wg-easy      — WireGuard web UI (Real-Debrid obviates VPN need)
#   WireGuard    — VPN tunnel (no longer required)
#   Docker       — container runtime (all services now native)
#
# Data preservation:
#   /opt/appdata/adguardhome/conf  → AdGuardHome config (reused in place)
#   /opt/appdata/adguardhome/work  → AdGuardHome state (reused in place)
#   /opt/appdata/vaultwarden       → Vaultwarden SQLite DB (reused in place)
#   /opt/appdata/caddy/data        → Caddy TLS certs (reused in place)
#   /opt/appdata/caddy/config      → Caddy config cache (reused in place)
#
# Run on Bahamut as root:
#   bash /opt/migrate-to-native.sh
#
# Idempotent: reruns skip completed steps. State stored in:
#   /var/lib/migrate-native/state
# Reset:
#   rm -rf /var/lib/migrate-native && bash /opt/migrate-to-native.sh
# =============================================================================
set -Eeuo pipefail

SCRIPT_NAME="migrate-to-native"
STATE_DIR="/var/lib/${SCRIPT_NAME}"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
BACKUP_DIR="/opt/appdata-backup-$(date +%Y%m%d-%H%M%S)"
DUCKDNS_TOKEN="32106606-1a70-4e0b-8bac-12ef5f2a7d5e"
VAULTWARDEN_DOMAIN="https://vaultwarden.lou-fogle-media-stack.duckdns.org"
HA_UPSTREAM="192.168.12.123:8123"
CADDY_CADDYFILE="/opt/appdata/caddy/Caddyfile"
ADGUARD_CONF_DIR="/opt/appdata/adguardhome/conf"
ADGUARD_WORK_DIR="/opt/appdata/adguardhome/work"
VW_DATA_DIR="/opt/appdata/vaultwarden"
CADDY_DATA_DIR="/opt/appdata/caddy/data"
CADDY_CONFIG_DIR="/opt/appdata/caddy/config"

exec > >(tee -a "$LOG_FILE") 2>&1

# ── Colours ──────────────────────────────────────────────────────────────────
info() { printf '\033[1;36m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1;35m── %s ──\033[0m\n' "$*"; }

# ── ERR trap ─────────────────────────────────────────────────────────────────
_on_err() {
  local rc=$? cmd=$BASH_COMMAND line=$1
  local fail_log
  fail_log="/var/log/${SCRIPT_NAME}-failure-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "=== FAILURE REPORT $(date) ==="
    echo "Line:    $line"
    echo "Command: $cmd"
    echo "Exit:    $rc"
    echo "Stack:   ${FUNCNAME[*]:-main}"
    echo "=== df -h ==="; df -h 2>/dev/null || true
    echo "=== free -m ==="; free -m 2>/dev/null || true
    echo "=== journal tail ==="; journalctl --no-pager -n 50 2>/dev/null || true
  } > "$fail_log"
  err "Failed at line $line: $cmd (exit $rc). Report: $fail_log"
}
trap '_on_err $LINENO' ERR

# ── Self-test ─────────────────────────────────────────────────────────────────
step "Self-test"
bash -n "$0" || { err "bash -n failed on $0"; exit 1; }
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$0" || true
else
  warn "shellcheck not found — installing"
  apt-get install -y -qq shellcheck
  shellcheck -S warning "$0" || true
fi
ok "Self-test passed"

# ── Root check ───────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { err "Must run as root"; exit 1; }

# ── State helpers ────────────────────────────────────────────────────────────
mkdir -p "$STATE_DIR"
step_done() { [ -f "${STATE_DIR}/$1" ]; }
mark_done() { touch "${STATE_DIR}/$1"; }

# ── Retry helper ─────────────────────────────────────────────────────────────
retry() {
  local tries=$1 pause=$2; shift 2
  local i=1
  while [ "$i" -le "$tries" ]; do
    "$@" && return 0
    warn "retry $i/$tries for: $*"; sleep "$pause"; i=$((i+1))
  done
  return 1
}

# =============================================================================
# STEP 0 — Preflight
# =============================================================================
step "Preflight"

ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] || { err "Expected aarch64, got $ARCH"; exit 1; }
ok "Architecture: aarch64"

. /etc/os-release
[ "${ID:-}" = "debian" ] || warn "Expected debian, got ${ID:-unknown} — proceeding"
ok "OS: ${PRETTY_NAME:-Debian}"

FREE_MB=$(df -m / | awk 'NR==2{print $4}')
[ "$FREE_MB" -ge 500 ] || { err "Need 500MB free on /, have ${FREE_MB}MB"; exit 1; }
ok "Disk free: ${FREE_MB}MB"

for url in \
  "https://github.com" \
  "https://api.github.com" \
  "https://caddyserver.com" \
  "https://duckdns.org"; do
  if retry 3 5 curl -fsS --max-time 12 -o /dev/null "$url"; then
    ok "  reachable: $url"
  else
    err "  unreachable: $url"; exit 1
  fi
done

# Validate DuckDNS token by doing a no-op update
DDNS_CHECK=$(curl -fsSL --max-time 10 \
  "https://www.duckdns.org/update?domains=lou-fogle-media-stack&token=${DUCKDNS_TOKEN}&ip=" 2>/dev/null || true)
[[ "$DDNS_CHECK" == "OK" ]] || warn "DuckDNS token check returned: ${DDNS_CHECK} (continuing — may be rate-limited)"

ok "Preflight passed"

# =============================================================================
# STEP 1 — Backup /opt/appdata
# =============================================================================
step "Backup /opt/appdata"
if ! step_done "backup"; then
  info "Backing up /opt/appdata → ${BACKUP_DIR}"
  cp -a /opt/appdata "${BACKUP_DIR}"
  ok "Backup complete: ${BACKUP_DIR}"
  mark_done "backup"
else
  ok "Backup already done — skipping"
fi

# =============================================================================
# STEP 2 — Stop and remove Docker containers + disable compose unit
# =============================================================================
step "Stop Docker services"
if ! step_done "docker_stop"; then
  systemctl stop docker-compose-stack.service 2>/dev/null || true
  systemctl disable docker-compose-stack.service 2>/dev/null || true
  for ct in caddy vaultwarden adguardhome wg-easy wireguard; do
    docker stop "$ct" 2>/dev/null || true
    docker rm -f "$ct" 2>/dev/null || true
  done
  ok "Docker containers stopped and removed"
  mark_done "docker_stop"
else
  ok "Docker already stopped — skipping"
fi

# =============================================================================
# STEP 3 — Install AdGuard Home (native binary)
# =============================================================================
step "Install AdGuard Home (native)"
if ! step_done "adguard_native"; then
  info "Fetching latest AdGuard Home release for linux_arm64 ..."
  AGH_TAG=$(retry 3 5 curl -fsS --max-time 15 \
    https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
  [ -n "$AGH_TAG" ] || { err "Could not determine AdGuardHome release tag"; exit 1; }
  info "AdGuardHome version: $AGH_TAG"

  AGH_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/${AGH_TAG}/AdGuardHome_linux_arm64.tar.gz"
  retry 3 10 curl -fSL --max-time 120 "$AGH_URL" -o /tmp/agh.tar.gz
  tar -xzf /tmp/agh.tar.gz -C /tmp
  install -m 0755 /tmp/AdGuardHome/AdGuardHome /usr/local/bin/AdGuardHome
  rm -rf /tmp/agh.tar.gz /tmp/AdGuardHome
  ok "AdGuardHome binary installed: $(/usr/local/bin/AdGuardHome --version 2>&1 | head -1)"

  # Ensure data dirs exist with correct ownership
  mkdir -p "$ADGUARD_CONF_DIR" "$ADGUARD_WORK_DIR"

  # Systemd unit
  cat >/etc/systemd/system/AdGuardHome.service <<'UNIT'
[Unit]
Description=AdGuard Home DNS/ad-blocker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/AdGuardHome \
  --config /opt/appdata/adguardhome/conf/AdGuardHome.yaml \
  --work-dir /opt/appdata/adguardhome/work \
  --no-check-update
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now AdGuardHome
  mark_done "adguard_native"
else
  ok "AdGuard Home already installed native — skipping"
fi

# Verify
for i in $(seq 1 15); do
  systemctl is-active AdGuardHome >/dev/null 2>&1 && break
  sleep 2
done
systemctl is-active AdGuardHome || { err "AdGuardHome failed to start"; journalctl -xeu AdGuardHome --no-pager | tail -20; exit 1; }
ok "AdGuardHome active"

# DNS probe
sleep 2
if dig +short +timeout=5 google.com @127.0.0.1 >/dev/null 2>&1; then
  ok "AdGuardHome DNS resolving google.com ✓"
else
  warn "AdGuardHome DNS probe failed — check config, continuing"
fi

# =============================================================================
# STEP 4 — Install Caddy with DuckDNS module (native binary)
# =============================================================================
step "Install Caddy + DuckDNS (native)"
if ! step_done "caddy_native"; then
  info "Downloading Caddy aarch64 with github.com/caddy-dns/duckdns ..."
  CADDY_URL="https://caddyserver.com/api/download?os=linux&arch=arm64&p=github.com/caddy-dns/duckdns"
  retry 3 15 curl -fsSL --max-time 120 "$CADDY_URL" -o /usr/local/bin/caddy
  chmod 0755 /usr/local/bin/caddy
  ok "Caddy installed: $(/usr/local/bin/caddy version 2>&1 | head -1)"

  # Verify DuckDNS module is present
  /usr/local/bin/caddy list-modules 2>/dev/null | grep -q 'dns.providers.duckdns' \
    || { err "DuckDNS module not found in caddy binary"; exit 1; }
  ok "DuckDNS module confirmed in Caddy binary"

  # Allow Caddy to bind :80/:443 as non-root
  setcap cap_net_bind_service=ep /usr/local/bin/caddy

  # Service user
  id -u caddy >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /var/lib/caddy caddy
  install -d -o caddy -g caddy -m 0750 /var/lib/caddy
  install -d -o caddy -g caddy -m 0750 "$CADDY_DATA_DIR" "$CADDY_CONFIG_DIR"

  # Write updated Caddyfile (wg-easy removed, HA route preserved)
  cat >"$CADDY_CADDYFILE" <<EOF
{
    email loufogle@gmail.com
    acme_dns duckdns ${DUCKDNS_TOKEN}
}

*.lou-fogle-media-stack.duckdns.org lou-fogle-media-stack.duckdns.org {
    tls {
        dns duckdns ${DUCKDNS_TOKEN}
        resolvers 8.8.8.8:53 1.1.1.1:53
    }

    @vaultwarden host vaultwarden.lou-fogle-media-stack.duckdns.org
    handle @vaultwarden {
        reverse_proxy localhost:8080
    }

    @adguard host adguard.lou-fogle-media-stack.duckdns.org
    handle @adguard {
        reverse_proxy localhost:8081
    }

    @ha host ha.lou-fogle-media-stack.duckdns.org
    handle @ha {
        reverse_proxy ${HA_UPSTREAM} {
            header_up Host {upstream_hostport}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
}
EOF
  chown caddy:caddy "$CADDY_CADDYFILE"
  ok "Caddyfile written (wg-easy route removed)"

  # Validate config before enabling
  /usr/local/bin/caddy validate --config "$CADDY_CADDYFILE" --adapter caddyfile \
    || { err "Caddyfile validation failed"; exit 1; }
  ok "Caddyfile validated"

  # Systemd unit
  cat >/etc/systemd/system/caddy.service <<UNIT
[Unit]
Description=Caddy reverse proxy (DuckDNS TLS)
After=network-online.target AdGuardHome.service
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --config ${CADDY_CADDYFILE} --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config ${CADDY_CADDYFILE} --adapter caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Environment=XDG_DATA_HOME=${CADDY_DATA_DIR}
Environment=XDG_CONFIG_HOME=${CADDY_CONFIG_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now caddy
  mark_done "caddy_native"
else
  ok "Caddy already installed native — skipping"
fi

# Verify
for i in $(seq 1 15); do
  systemctl is-active caddy >/dev/null 2>&1 && break
  sleep 2
done
systemctl is-active caddy || { err "Caddy failed to start"; journalctl -xeu caddy --no-pager | tail -20; exit 1; }
ok "Caddy active"

# =============================================================================
# STEP 5 — Install Vaultwarden (native ARM64 binary)
# =============================================================================
step "Install Vaultwarden (native)"
if ! step_done "vaultwarden_native"; then
  info "Fetching latest Vaultwarden release for aarch64 ..."
  VW_TAG=$(retry 3 5 curl -fsS --max-time 15 \
    https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
  [ -n "$VW_TAG" ] || { err "Could not determine Vaultwarden release tag"; exit 1; }
  info "Vaultwarden version: $VW_TAG"

  # Find the aarch64 musl asset
  VW_ASSET=$(retry 3 5 curl -fsS --max-time 15 \
    "https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest" \
    | grep '"browser_download_url"' \
    | grep -i 'aarch64.*musl\|arm64.*musl\|aarch64-unknown-linux-musl' \
    | head -1 \
    | sed 's/.*"browser_download_url": *"\(.*\)".*/\1/')

  if [ -z "$VW_ASSET" ]; then
    # Fallback: look for any aarch64 binary
    VW_ASSET=$(retry 3 5 curl -fsS --max-time 15 \
      "https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest" \
      | grep '"browser_download_url"' \
      | grep -i 'aarch64\|arm64' \
      | grep -v '\.sha256\|\.sig' \
      | head -1 \
      | sed 's/.*"browser_download_url": *"\(.*\)".*/\1/')
  fi

  [ -n "$VW_ASSET" ] || { err "Could not find Vaultwarden aarch64 release asset"; exit 1; }
  info "Downloading: $VW_ASSET"

  retry 3 10 curl -fsSL --max-time 120 "$VW_ASSET" -o /tmp/vaultwarden_dl
  # Asset may be a tarball or a raw binary
  file_type=$(file /tmp/vaultwarden_dl 2>/dev/null || true)
  if echo "$file_type" | grep -qi 'gzip\|tar\|compress'; then
    tar -xzf /tmp/vaultwarden_dl -C /tmp
    VW_BIN=$(find /tmp -maxdepth 2 -name 'vaultwarden' -type f | head -1)
  else
    VW_BIN="/tmp/vaultwarden_dl"
  fi
  [ -n "$VW_BIN" ] && [ -f "$VW_BIN" ] || { err "Cannot locate vaultwarden binary after download"; exit 1; }
  install -m 0755 "$VW_BIN" /usr/local/bin/vaultwarden
  rm -f /tmp/vaultwarden_dl
  ok "Vaultwarden binary installed"

  # Service user and data dir
  id -u vaultwarden >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d "$VW_DATA_DIR" vaultwarden
  mkdir -p "$VW_DATA_DIR"
  chown -R vaultwarden:vaultwarden "$VW_DATA_DIR"
  chmod 0750 "$VW_DATA_DIR"

  # Env file (secrets not in unit file)
  cat >/etc/vaultwarden.env <<EOF
ROCKET_ADDRESS=0.0.0.0
ROCKET_PORT=8080
DATA_FOLDER=${VW_DATA_DIR}
DOMAIN=${VAULTWARDEN_DOMAIN}
SIGNUPS_ALLOWED=false
LOG_LEVEL=warn
EOF
  chmod 0600 /etc/vaultwarden.env

  # Systemd unit
  cat >/etc/systemd/system/vaultwarden.service <<UNIT
[Unit]
Description=Vaultwarden password manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=vaultwarden
Group=vaultwarden
EnvironmentFile=/etc/vaultwarden.env
ExecStart=/usr/local/bin/vaultwarden
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now vaultwarden
  mark_done "vaultwarden_native"
else
  ok "Vaultwarden already installed native — skipping"
fi

# Verify
for i in $(seq 1 15); do
  systemctl is-active vaultwarden >/dev/null 2>&1 && break
  sleep 2
done
systemctl is-active vaultwarden || { err "Vaultwarden failed to start"; journalctl -xeu vaultwarden --no-pager | tail -20; exit 1; }
# HTTP probe
for i in $(seq 1 10); do
  code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/ 2>/dev/null || true)
  [ "$code" = "200" ] || [ "$code" = "302" ] || [ "$code" = "301" ] && break
  sleep 2
done
ok "Vaultwarden active (HTTP $code)"

# =============================================================================
# STEP 6 — Remove Docker, WireGuard, wg-easy
# =============================================================================
step "Remove Docker + WireGuard"
if ! step_done "docker_removed"; then
  info "Purging Docker and WireGuard packages ..."
  # Remove all Docker containers/images/volumes first
  docker system prune -af --volumes 2>/dev/null || true
  systemctl stop docker 2>/dev/null || true
  systemctl disable docker 2>/dev/null || true

  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    docker-buildx-plugin docker.io docker-compose \
    wireguard wireguard-tools 2>/dev/null || true

  apt-get autoremove -y --purge 2>/dev/null || true
  rm -f /etc/systemd/system/docker-compose-stack.service
  rm -f /opt/docker-compose.yml /opt/Dockerfile.caddy 2>/dev/null || true
  rm -rf /opt/appdata/wg-easy 2>/dev/null || true
  systemctl daemon-reload
  ok "Docker and WireGuard removed"
  mark_done "docker_removed"
else
  ok "Docker already removed — skipping"
fi

# =============================================================================
# STEP 7 — Final verification
# =============================================================================
step "End-to-end verification"
ALL_OK=1

for svc in AdGuardHome vaultwarden caddy; do
  state=$(systemctl is-active "$svc" 2>/dev/null || true)
  if [ "$state" = "active" ]; then
    ok "  $svc: active"
  else
    err "  $svc: $state"
    journalctl -xeu "$svc" --no-pager | tail -10 | sed 's/^/    | /'
    ALL_OK=0
  fi
done

# DNS
if dig +short +timeout=5 google.com @127.0.0.1 >/dev/null 2>&1; then
  ok "  DNS (AdGuard :53): resolving ✓"
else
  err "  DNS probe failed"; ALL_OK=0
fi

# Vaultwarden HTTP
vw_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/ 2>/dev/null || true)
[ "$vw_code" = "200" ] || [ "$vw_code" = "302" ] || [ "$vw_code" = "301" ] \
  && ok "  Vaultwarden :8080 → $vw_code ✓" \
  || { err "  Vaultwarden :8080 → $vw_code"; ALL_OK=0; }

# AdGuard admin HTTP
ag_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8081/ 2>/dev/null || true)
[ "$ag_code" = "200" ] || [ "$ag_code" = "302" ] || [ "$ag_code" = "301" ] \
  && ok "  AdGuard admin :8081 → $ag_code ✓" \
  || { err "  AdGuard admin :8081 → $ag_code"; ALL_OK=0; }

# Caddy (port 80 redirect)
caddy_code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/ 2>/dev/null || true)
[ "$caddy_code" = "200" ] || [ "$caddy_code" = "301" ] || [ "$caddy_code" = "308" ] \
  && ok "  Caddy :80 → $caddy_code ✓" \
  || warn "  Caddy :80 → $caddy_code (may redirect to HTTPS — check manually)"

# Memory freed
echo ""
info "Memory after migration:"
free -h

# =============================================================================
cat <<EOF

============================================================
  Bahamut native migration complete
============================================================
  AdGuardHome   native systemd   DNS :53    admin :8081
  Vaultwarden   native systemd   :8080      data: ${VW_DATA_DIR}
  Caddy         native systemd   :80/:443   DuckDNS TLS

  External URLs (once DNS propagates):
    https://vaultwarden.lou-fogle-media-stack.duckdns.org
    https://adguard.lou-fogle-media-stack.duckdns.org
    https://ha.lou-fogle-media-stack.duckdns.org

  Removed: Docker, WireGuard, wg-easy
  Backup:  ${BACKUP_DIR}
  Log:     ${LOG_FILE}

  Verify:
    systemctl status AdGuardHome vaultwarden caddy
    journalctl -fu caddy
    dig google.com @127.0.0.1
============================================================
EOF

if [ "$ALL_OK" -eq 1 ]; then
  ok "Migration complete — all services healthy."
else
  err "One or more checks failed. See above and check: journalctl -fu <service>"
  exit 1
fi
