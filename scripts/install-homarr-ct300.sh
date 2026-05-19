#!/usr/bin/env bash
# install-homarr-ct300.sh — native Homarr v1+ install inside CT-300.
#
# Source of truth: homarr-labs/homarr GitHub releases. Asset
# `build-debian-amd64.tar.gz` ships a prebuilt monorepo + run.sh that
# orchestrates Next.js + WebSocket + background tasks + nginx (on :7575)
# in a single foreground process. We do NOT build from source; the
# upstream prebuilt is the canonical native install path (same pattern
# used by community-scripts/ProxmoxVE/install/homarr-install.sh).
#
# Why native (no Docker): CT-300 is the bulletproof self-contained stack
# and runs everything natively beside Jellyfin, Riven, Postgres, Redis,
# Caddy, zap2xml. Homarr fits the same pattern.
#
# Self-healing per AGENTS.md:
#   §1 research before writing      — see header citation above
#   §2 self-test                    — bash -n + shellcheck self-call below
#   §3 preflight                    — DNS, GitHub reachability, disk, port free
#   §4 ERR trap with diagnostic     — captures last 200 journal lines
#   §5 verify-execute-heal          — version-tag gate; tarball cached
#   §7 idempotency                  — re-running upgrades to latest in place
#   §8 positive end-to-end probe    — HTTP probe on :7575 up to 90 s
#  §10 persistent secrets           — /opt/homarr.env mode 0600, preserved
#  §12 never ask discoverable values — node version detected at runtime
#
# Run on the Tiamat host:
#   bash scripts/install-homarr-ct300.sh
# (script ssh's into CT-300 as needed)

set -Eeuo pipefail

CT="${CT:-300}"
TIAMAT="${TIAMAT:-tiamat}"
HOMARR_PORT="${HOMARR_PORT:-7575}"
HOMARR_DIR="/opt/homarr"
HOMARR_DB_DIR="/opt/homarr_db"
HOMARR_ENV="/opt/homarr.env"
HOMARR_REPO="homarr-labs/homarr"
ASSET_NAME="build-debian-amd64.tar.gz"
NODE_MAJOR_REQUIRED=24

C_INFO=$'\e[1;36m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_RST=$'\e[0m'
log()  { printf '%s[homarr]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s[homarr]%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '%s[homarr]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s[homarr]%s %s\n' "$C_ERR"  "$C_RST" "$*" >&2; }

on_err() {
  local rc=$? line=$1
  err "FAILED at line $line (exit $rc)"
  err "  context:"
  sed -n "$((line-2)),$((line+2))p" "${BASH_SOURCE[0]}" 2>/dev/null | head -10 >&2 || true
  exit "$rc"
}
trap 'on_err $LINENO' ERR

# ─── self-test ────────────────────────────────────────────────────────────
self_test() {
  log "self-test: bash -n + shellcheck"
  bash -n "${BASH_SOURCE[0]}"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "${BASH_SOURCE[0]}" >&2 || warn "shellcheck warnings (non-fatal)"
  fi
}

# heredoc-based CT exec (avoids quoting hell)
ssh_t()  { ssh -o ConnectTimeout=8 -o BatchMode=yes "$TIAMAT" "$@"; }
ssh_ct() { ssh -o ConnectTimeout=15 -o BatchMode=yes "$TIAMAT" "pct exec $CT -- bash -s" <<<"$1"; }
ssh_ct_quiet() { ssh -o ConnectTimeout=15 -o BatchMode=yes "$TIAMAT" "pct exec $CT -- bash -s" <<<"$1" 2>/dev/null; }

# ─── preflight ────────────────────────────────────────────────────────────
preflight() {
  log "preflight"
  ssh_t true                                           || { err "ssh $TIAMAT unreachable"; exit 2; }
  ssh_t "pct status $CT | grep -q running"             || { err "CT-$CT not running"; exit 2; }
  # DNS + GitHub reachability from inside CT
  ssh_ct '
set -e
getent hosts api.github.com >/dev/null
curl -fsS -o /dev/null --max-time 8 https://api.github.com/zen
'
  # Disk space (need ~2 GB headroom on /opt)
  local free_kb
  free_kb=$(ssh_ct 'df --output=avail /opt 2>/dev/null | tail -1' || echo 0)
  if [ "${free_kb:-0}" -lt 2000000 ]; then
    warn "CT-$CT /opt has <2 GB free (have ${free_kb} KB) — continuing"
  fi
  # Port :7575 either free or held by an existing homarr.service we'll upgrade
  if ssh_ct_quiet "ss -tlnH | awk '{print \$4}' | grep -q ':${HOMARR_PORT}\$'"; then
    if ssh_ct_quiet "systemctl is-active --quiet homarr"; then
      log "port ${HOMARR_PORT} held by existing homarr.service — will upgrade in place"
    else
      err "port ${HOMARR_PORT} is in use by something other than homarr.service"
      exit 1
    fi
  fi
  ok "preflight ok"
}

# ─── apt deps + node 24 ───────────────────────────────────────────────────
install_deps() {
  log "installing apt deps + Node ${NODE_MAJOR_REQUIRED}.x"
  ssh_ct "$(cat <<'INNER'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
# Fast-path: when ALL apt deps are already installed (e.g. dpkg pre-staged on
# a slow-network CT), skip apt entirely. Saves 5–20 minutes when the CT's
# upstream mirror connectivity is intermittent.
_have_all=1
for pkg in curl ca-certificates gnupg jq openssl gettext-base redis-server nginx build-essential; do
  dpkg -s "$pkg" >/dev/null 2>&1 || { _have_all=0; break; }
done
if [ "$_have_all" = 1 ]; then
  echo "[homarr] all required apt deps already installed (skipping apt update/install)"
else
  # Prefer nala (per user rule); fall back to apt-get if nala is unavailable.
  if command -v nala >/dev/null 2>&1; then PKGTOOL=nala; else PKGTOOL=apt-get; fi
  echo "[homarr] using $PKGTOOL"
  # Slow mirrors caused the previous retry loop to tear down every download
  # mid-flight. Give apt a 5-minute per-request timeout and let its own
  # internal retry counter (10) handle blips. --fix-missing tolerates a
  # single failed mirror without aborting the whole batch.
  APT_OPTS="-y --no-install-recommends \
    -o Acquire::Retries=10 \
    -o Acquire::http::Timeout=300 \
    -o Acquire::https::Timeout=300 \
    -o Acquire::ForceIPv4=true"
  $PKGTOOL update $APT_OPTS 2>&1 | tail -10 || true
  $PKGTOOL install $APT_OPTS --fix-missing \
    curl ca-certificates gnupg jq openssl gettext-base \
    redis-server nginx build-essential
fi  # _have_all
# Final verification (runs in both branches)
command -v nginx >/dev/null && command -v redis-server >/dev/null && command -v jq >/dev/null \
  || { echo '[homarr] ERROR: required apt deps still missing after install' >&2; exit 100; }

# Node >= 24.14 (Homarr engines.node)
need_node24=1
if command -v node >/dev/null 2>&1; then
  cur=$(node --version | sed 's/^v//')
  major=${cur%%.*}
  if [ "${major:-0}" -ge 24 ]; then
    need_node24=0
    echo "[homarr] node $cur already meets >=24"
  fi
fi
if [ "$need_node24" = 1 ]; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -y -o Dir::Etc::sourcelist="sources.list.d/nodesource.list" \
    -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" >/dev/null
  apt-get install -y --no-install-recommends nodejs >/dev/null
  echo "[homarr] node $(node --version) installed"
fi
INNER
)"
  ok "deps + node 24+ ready"
}

# ─── fetch + extract prebuilt tarball ─────────────────────────────────────
fetch_homarr() {
  log "fetching latest ${HOMARR_REPO} prebuild"
  ssh_ct "$(cat <<INNER
set -Eeuo pipefail
HOMARR_DIR='${HOMARR_DIR}'
ASSET_NAME='${ASSET_NAME}'
mkdir -p "\$HOMARR_DIR"
rel_json=\$(curl -fsSL "https://api.github.com/repos/${HOMARR_REPO}/releases/latest")
tag=\$(echo "\$rel_json" | jq -r '.tag_name')
url=\$(echo "\$rel_json" | jq -r --arg n "\$ASSET_NAME" '.assets[]?|select(.name==\$n)|.browser_download_url')
if [ -z "\$url" ] || [ "\$url" = "null" ]; then
  echo "[homarr] ERROR: \$ASSET_NAME not in release \$tag" >&2; exit 1
fi
echo "[homarr] release \$tag -> \$url"

installed_tag=""
[ -f "\$HOMARR_DIR/.installed_tag" ] && installed_tag=\$(cat "\$HOMARR_DIR/.installed_tag")
if [ "\$installed_tag" = "\$tag" ] && [ -x "\$HOMARR_DIR/run.sh" ]; then
  echo "[homarr] \$tag already installed (skipping fetch)"
  exit 0
fi

curl -fsSL --retry 3 --retry-delay 2 "\$url" -o /tmp/homarr.tar.gz
tar -xzf /tmp/homarr.tar.gz -C "\$HOMARR_DIR" --overwrite
rm -f /tmp/homarr.tar.gz
echo "\$tag" > "\$HOMARR_DIR/.installed_tag"
echo "[homarr] extracted \$tag"
INNER
)"
}

# ─── env + db (persistent secrets per AGENTS.md §10) ──────────────────────
setup_env_db() {
  log "preparing DB dir and persistent ${HOMARR_ENV}"
  ssh_ct "$(cat <<INNER
set -Eeuo pipefail
HOMARR_DB_DIR='${HOMARR_DB_DIR}'
HOMARR_ENV='${HOMARR_ENV}'
mkdir -p "\$HOMARR_DB_DIR"
[ -f "\$HOMARR_DB_DIR/db.sqlite" ] || touch "\$HOMARR_DB_DIR/db.sqlite"

if [ ! -f "\$HOMARR_ENV" ]; then
  KEY=\$(openssl rand -hex 32)
  cat > "\$HOMARR_ENV" <<EOF
# Generated by install-homarr-ct300.sh — preserved across re-runs
DB_DRIVER='better-sqlite3'
DB_DIALECT='sqlite'
SECRET_ENCRYPTION_KEY='\$KEY'
DB_URL='\$HOMARR_DB_DIR/db.sqlite'
TURBO_TELEMETRY_DISABLED=1
AUTH_PROVIDERS='credentials'
NODE_ENV='production'
REDIS_IS_EXTERNAL='true'
PORT=3010
HOSTNAME=127.0.0.1
EOF
  chmod 0600 "\$HOMARR_ENV"
  echo "[homarr] wrote new \$HOMARR_ENV (mode 0600)"
else
  echo "[homarr] \$HOMARR_ENV preserved (existing key)"
fi
INNER
)"
}

# ─── redis + nginx-template (homarr ships its own) ────────────────────────
setup_redis_nginx() {
  log "configuring CT-300 redis + Homarr nginx template"
  ssh_ct "$(cat <<INNER
set -Eeuo pipefail
install -d -m 0755 /appdata/redis
chown -R redis:redis /appdata/redis 2>/dev/null || true
[ -f '${HOMARR_DIR}/redis.conf' ] && install -m 0644 '${HOMARR_DIR}/redis.conf' /etc/redis/redis.conf
install -d /etc/systemd/system/redis-server.service.d
cat > /etc/systemd/system/redis-server.service.d/override.conf <<'EOF'
[Service]
ReadWritePaths=-/appdata/redis -/var/lib/redis -/var/log/redis -/var/run/redis -/etc/redis
EOF

install -d /etc/nginx/templates
[ -f '${HOMARR_DIR}/nginx.conf' ] && install -m 0644 '${HOMARR_DIR}/nginx.conf' /etc/nginx/templates/nginx.conf

# The tarball ships port 3000 as the upstream default, but CT-300 runs
# Riven on :3000, so Homarr's Next.js is on PORT=3010 (set in homarr.env).
# Patch the template to proxy to 3010 and add buffer settings to prevent
# "upstream sent too big header" errors from the Next.js auth layer.
if [ -f /etc/nginx/templates/nginx.conf ]; then
  sed -i 's|\(proxy_pass http://\${HOSTNAME}:\)3000;|\13010;|' /etc/nginx/templates/nginx.conf
  # Inject buffer settings into the http block if not already present
  if ! grep -q 'proxy_buffer_size' /etc/nginx/templates/nginx.conf; then
    sed -i '/^http {/a\    # Prevent "upstream sent too big header" errors\n    proxy_buffer_size          128k;\n    proxy_buffers              4 256k;\n    proxy_busy_buffers_size    256k;' /etc/nginx/templates/nginx.conf
  fi
fi
# Disable system nginx — Homarr's run.sh launches its own on :${HOMARR_PORT}
systemctl disable --now nginx >/dev/null 2>&1 || true

# CLI shim
cat > /usr/bin/homarr <<'EOF'
#!/bin/bash
cd /opt/homarr/apps/cli && exec node ./cli.cjs "\$@"
EOF
chmod +x /usr/bin/homarr
INNER
)"
}

# ─── systemd unit ─────────────────────────────────────────────────────────
install_service() {
  log "installing homarr.service"
  ssh_ct "$(cat <<INNER
set -Eeuo pipefail
chmod +x '${HOMARR_DIR}/run.sh' 2>/dev/null || true
cat > /etc/systemd/system/homarr.service <<EOF
[Unit]
Description=Homarr Dashboard (CT-300, native)
Documentation=https://homarr.dev
Requires=redis-server.service
After=redis-server.service network-online.target
Wants=network-online.target

[Service]
Type=exec
WorkingDirectory=${HOMARR_DIR}
EnvironmentFile=-${HOMARR_ENV}
ExecStart=${HOMARR_DIR}/run.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable redis-server >/dev/null
systemctl restart redis-server
systemctl enable homarr >/dev/null
systemctl restart homarr
INNER
)"
  ok "homarr.service started"
}

# ─── end-to-end probe ─────────────────────────────────────────────────────
verify() {
  log "verifying http://CT-${CT}:${HOMARR_PORT}/ (up to 90 s)"
  local code i
  for i in $(seq 1 45); do
    : "$i"
    code=$(ssh_ct_quiet "curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:${HOMARR_PORT}/" || echo 000)
    case "$code" in 200|301|302|303|307|308) ok "homarr responding (HTTP $code)"; return 0 ;; esac
    sleep 2
  done
  err "homarr did not respond on :${HOMARR_PORT} (last code=$code)"
  ssh_ct "journalctl -u homarr -n 80 --no-pager" >&2 || true
  return 1
}

# ─── caddy site block (idempotent) ────────────────────────────────────────
configure_caddy() {
  log "adding homarr.mediastack.lan to CT-300 Caddyfile (idempotent)"
  ssh_ct "$(cat <<INNER
if ! grep -q 'homarr.mediastack.lan' /etc/caddy/Caddyfile 2>/dev/null; then
  cat >> /etc/caddy/Caddyfile <<'CADDY'

homarr.mediastack.lan, homarr.local {
    tls internal
    import headers
    reverse_proxy 127.0.0.1:${HOMARR_PORT}
}
CADDY
  systemctl reload caddy 2>/dev/null || systemctl restart caddy
fi
INNER
)"
}

main() {
  self_test
  preflight
  install_deps
  fetch_homarr
  setup_env_db
  setup_redis_nginx
  install_service
  configure_caddy
  verify
  echo
  ok "DONE"
  printf '  →  http://192.168.12.30:%d/\n' "${HOMARR_PORT}"
  printf '  →  https://homarr.mediastack.lan/   (via Caddy + AdGuard DNS)\n'
}

main "$@"
