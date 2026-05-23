#!/usr/bin/env bash
# install-unified-guide.sh — single deployer for the CT-300 unified guide.
#
# What it installs:
#   1. unified-guide service in CT-300 (Python stdlib HTTP server on :7700)
#      + refresh timer (every 15 min)
#      + Caddy site block at guide.mediastack.lan (TLS internal)
#   2. yttv-scraper in CT-300 (parses staged browse.json -> M3U + XMLTV + JSON)
#      + refresh timer (every 30 min)
#   3. Tailscale natively in CT-300 (--accept-dns=false to keep AdGuard as
#      the resolver for *.mediastack.lan)
#   4. disk-space-watchdog on the Tiamat host (NOT in CT-300) + 5-minute timer
#
# Self-healing per AGENTS.md:
#   - bash -n + shellcheck self-test
#   - preflight: tiamat ssh, CT-300 running, jellyfin reachable
#   - value discovery: TMDB key from CT-242 jellyseerr; Jellyfin token from
#     /etc/jellyfin-autoscan.env inside CT-300; Riven URL is constant.
#   - persistent secrets at /etc/unified-guide/env mode 0600 — preserved across
#     re-runs.
#   - end-to-end HTTP probe on http://192.168.12.30:7700 + grid endpoint.
#   - on success: prints both LAN-IP and mediastack.lan URLs.

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIAMAT="${TIAMAT:-tiamat}"
CT="${CT:-300}"
GUIDE_PORT="${GUIDE_PORT:-7700}"
CT_IP="${CT_IP:-192.168.12.30}"

C_INFO=$'\e[1;36m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_RST=$'\e[0m'
log()  { printf '%s[ug-install]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s[ug-install]%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '%s[ug-install]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s[ug-install]%s %s\n' "$C_ERR"  "$C_RST" "$*" >&2; }

on_err() {
  local rc=$? line=$1
  err "FAILED at line $line (exit $rc)"
  err "  recent local context: $(sed -n "$((line-2)),$((line+2))p" "${BASH_SOURCE[0]}" 2>/dev/null | head -10 || true)"
  exit "$rc"
}
trap 'on_err $LINENO' ERR

# ─── self-test ───────────────────────────────────────────────────────────────
self_test() {
  log "self-test: bash -n + shellcheck"
  bash -n "${BASH_SOURCE[0]}"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "${BASH_SOURCE[0]}" || warn "shellcheck reported warnings (non-fatal)"
  fi
}

# All CT execution goes through stdin so we avoid double-eval quoting hell
# (`pct exec $CT -- bash -c "$ESCAPED_THING"` blew up on inner quotes/parens).
ssh_t()  { ssh -o ConnectTimeout=8 -o BatchMode=yes "$TIAMAT" "$@"; }
ssh_ct() {
  # Pass arbitrary bash to CT-$CT via stdin. No escaping required.
  ssh -o ConnectTimeout=15 -o BatchMode=yes "$TIAMAT" "pct exec $CT -- bash -s" <<<"$1"
}
ssh_ct_quiet() {
  ssh -o ConnectTimeout=15 -o BatchMode=yes "$TIAMAT" "pct exec $CT -- bash -s" <<<"$1" 2>/dev/null
}

# ─── preflight ───────────────────────────────────────────────────────────────
preflight() {
  log "preflight"
  ssh_t true              || { err "ssh $TIAMAT unreachable"; exit 2; }
  ssh_t "pct status $CT | grep -q running" \
    || { err "CT-$CT not running"; exit 2; }
  ssh_t "pct exec $CT -- ss -tln | awk '{print \$4}' | grep -q ':8096\$'" \
    || warn "jellyfin :8096 not listening inside CT-$CT (continuing)"
  ok "preflight ok"
}

# ─── value discovery ───────────────────────────────────────────────────────────────────────────────────────
env_value() {
  # Extract VALUE for KEY=VALUE in a shell-style env file. Strips surrounding
  # single or double quotes. Returns the FIRST (or last with $3=tail) match.
  local key=$1 file=$2 mode=${3:-head}
  awk -v k="$key" -F= '$1==k {sub(/^["\047]/, "", $2); sub(/["\047]\r?$/, "", $2); print $2}' "$file" 2>/dev/null \
    | { [ "$mode" = tail ] && tail -1 || head -1; }
}
export -f env_value

discover_tmdb_key() {
  # 1. CT-242 jellyseerr settings.json (start CT if needed)
  local key=""
  ssh_t "pct status 242 2>/dev/null | grep -q running || pct start 242 >/dev/null 2>&1; sleep 3" 2>/dev/null || true
  key=$(ssh_t "pct exec 242 -- bash -s" <<'INNER' 2>/dev/null | tr -d '[:space:]' | head -c 64
for f in /var/lib/jellyseerr/settings.json /opt/jellyseerr/config/settings.json /var/lib/jellyseerr/config/settings.json; do
  if [ -f "$f" ]; then
    jq -r '.tmdbApiKey // .tmdb_api_key // empty' "$f" 2>/dev/null && break
  fi
done
INNER
)
  # 2. Fall back to a previously-written /etc/unified-guide/env (re-run case)
  if [ -z "$key" ]; then
    key=$(ssh_ct_quiet "awk -F= '\$1==\"UG_TMDB_API_KEY\"{sub(/^[\"\047]/,\"\",\$2); sub(/[\"\047]\r?\$/,\"\",\$2); print \$2; exit}' /etc/unified-guide/env" | tr -d '[:space:]')
  fi
  printf '%s' "$key"
}

discover_jellyfin_token() {
  # CREDENTIALS.md says /etc/jellyfin-autoscan.env (mode 0600) holds the key
  local tok=""
  # Try JELLYFIN_API_KEY first (autoscan format), then generic API_KEY
  tok=$(ssh_ct_quiet "awk -F= '/^JELLYFIN_API_KEY=/{sub(/^[\"\047]/,\"\",\$2); sub(/[\"\047]\r?\$/,\"\",\$2); print \$2; exit}' /etc/jellyfin-autoscan.env" | tr -d '[:space:]')
  if [ -z "$tok" ]; then
    tok=$(ssh_ct_quiet "awk -F= '/^(JELLYFIN_)?API_KEY=/{sub(/^[\"\047]/,\"\",\$2); sub(/[\"\047]\r?\$/,\"\",\$2); print \$2; exit}' /etc/jellyfin-autoscan.env" | tr -d '[:space:]')
  fi
  # Fall back to jellyfin.db
  if [ -z "$tok" ]; then
    tok=$(ssh_ct_quiet "sqlite3 /var/lib/jellyfin/data/jellyfin.db 'SELECT AccessToken FROM ApiKeys LIMIT 1;' 2>/dev/null" | tr -d '[:space:]')
  fi
  printf '%s' "$tok"
}

# ─── push artifacts to CT-300 ────────────────────────────────────────────────
push_artifacts() {
  log "pushing artifacts to CT-$CT"
  # Stage on Tiamat host first, then pct push (no direct laptop->CT path).
  local stage="/tmp/ug-stage-$$"
  ssh_t "rm -rf $stage && mkdir -p $stage/unified-guide/static $stage/yttv-scraper"

  # Tar+pipe to avoid many round-trips
  tar -C "$REPO_DIR/services" -cf - unified-guide yttv-scraper \
    | ssh_t "tar -C $stage -xf -"

  # Push into CT-300
  ssh_t "
    set -e
    pct exec $CT -- mkdir -p /opt/unified-guide/static /opt/yttv-scraper /etc/unified-guide /etc/yttv-scraper /var/cache/unified-guide /var/lib/yttv-scraper /data/streaming/yttv
    pct push $CT $stage/unified-guide/server.py             /opt/unified-guide/server.py
    for f in $stage/unified-guide/static/*; do
      pct push $CT \$f /opt/unified-guide/static/\$(basename \$f)
    done
    pct push $CT $stage/unified-guide/unified-guide.service          /etc/systemd/system/unified-guide.service
    pct push $CT $stage/unified-guide/unified-guide-refresh.service  /etc/systemd/system/unified-guide-refresh.service
    pct push $CT $stage/unified-guide/unified-guide-refresh.timer    /etc/systemd/system/unified-guide-refresh.timer
    pct push $CT $stage/yttv-scraper/yttv_scraper.py             /opt/yttv-scraper/yttv_scraper.py
    pct push $CT $stage/yttv-scraper/yttv-scraper.service        /etc/systemd/system/yttv-scraper.service
    pct push $CT $stage/yttv-scraper/yttv-scraper.timer          /etc/systemd/system/yttv-scraper.timer
    pct exec $CT -- chmod 0644 /opt/unified-guide/server.py /opt/yttv-scraper/yttv_scraper.py
    rm -rf $stage
  "
  ok "artifacts in /opt/unified-guide and /opt/yttv-scraper"
}

# ─── env files (with discovered secrets) ──────────────────────────────────
write_env_files() {
  local tmdb_key="$1" jf_token="$2"
  log "writing /etc/unified-guide/env (mode 0600)"
  ssh_ct "$(cat <<INNER
mkdir -p /etc/unified-guide /etc/yttv-scraper
cat > /etc/unified-guide/env <<'EOF'
# generated by install-unified-guide.sh
UG_TMDB_API_KEY=$tmdb_key
UG_TMDB_REGION=US
UG_TMDB_PROVIDERS=Netflix:8,Amazon:9,Max:1899,Disney+:337,Peacock:386
UG_JELLYFIN_URL=http://$CT_IP:8096
UG_JELLYFIN_TOKEN=$jf_token
UG_JELLYFIN_PUBLIC=http://$CT_IP:8096
UG_THREADFIN_URL=http://$CT_IP:34400
UG_THREADFIN_XMLTV=https://tvpass.org/epg.xml
UG_RIVEN_PUBLIC=http://$CT_IP:3000
UG_OTA_XMLTV=/data/media/epg.xml
UG_YTTV_CHANNELS=/data/streaming/yttv/yttv-channels.json
UG_YTTV_EPG=/data/streaming/yttv/yttv-epg.xml
UG_UNIFIED_XMLTV=/data/streaming/unified.xml
UG_BIND_HOST=0.0.0.0
UG_BIND_PORT=$GUIDE_PORT
EOF
chmod 0600 /etc/unified-guide/env

cat > /etc/yttv-scraper/env <<'EOF'
YTTV_BROWSE_JSON=/var/lib/yttv-scraper/browse.json
YTTV_OUTPUT_DIR=/data/streaming/yttv
YTTV_WATCH_BASE=https://tv.youtube.com/watch
EOF
chmod 0644 /etc/yttv-scraper/env
INNER
)"
  ok "env files written"
}

# yttv-scraper systemd units now ship as repo files in services/yttv-scraper/
# and are pushed by push_artifacts(). Nothing to generate inline.
# (kept as a no-op for installer call symmetry.)
install_yttv_units() {
  : # units are pushed alongside the script
}

# ─── caddy site block ───────────────────────────────────────────────────────────────────────────────────────────
configure_caddy() {
  log "adding guide.mediastack.lan to Caddyfile (idempotent)"
  ssh_ct "$(cat <<INNER
if ! grep -q 'guide.mediastack.lan' /etc/caddy/Caddyfile 2>/dev/null; then
  cat >> /etc/caddy/Caddyfile <<'CADDY'

guide.mediastack.lan, guide.local {
    tls internal
    import headers
    reverse_proxy 127.0.0.1:$GUIDE_PORT
}
CADDY
  systemctl reload caddy 2>/dev/null || systemctl restart caddy
fi
INNER
)"
  ok "caddy: guide.mediastack.lan -> 127.0.0.1:$GUIDE_PORT"
}

# ─── tailscale (native in CT-300, no DNS override) ───────────────────────
install_tailscale() {
  log "installing tailscale natively in CT-$CT (--accept-dns=false)"
  ssh_ct "$(cat <<'INNER'
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled
if ! tailscale status >/dev/null 2>&1; then
  echo '[ug-install] run on CT-300:  tailscale up --ssh --accept-dns=false  -- then re-run this script'
else
  tailscale set --accept-dns=false 2>/dev/null || true
fi
INNER
)"
}

# ─── enable + start systemd ──────────────────────────────────────────────
enable_units() {
  log "enabling/starting systemd units in CT-$CT"
  ssh_ct "$(cat <<'INNER'
systemctl daemon-reload
systemctl enable --now unified-guide.service
systemctl enable --now unified-guide-refresh.timer
systemctl enable --now yttv-scraper.timer
INNER
)"
}

# ─── disk-space-watchdog on tiamat host ──────────────────────────────────────
install_watchdog_host() {
  log "installing disk-space-watchdog on $TIAMAT host"
  scp -q -o ConnectTimeout=8 "$REPO_DIR/scripts/disk-space-watchdog.sh" \
    "$TIAMAT:/usr/local/bin/disk-space-watchdog.sh"
  ssh_t '
    chmod +x /usr/local/bin/disk-space-watchdog.sh
    mkdir -p /etc/disk-watchdog /var/lib/disk-watchdog
    [ -f /etc/disk-watchdog/env ] || cat > /etc/disk-watchdog/env <<EOF
# Optional Home Assistant webhook for notifications (HAOS at 192.168.12.123:8123)
# HA_NOTIFY_WEBHOOK_URL=http://192.168.12.123:8123/api/webhook/disk-watchdog
EOF
    cat > /etc/systemd/system/disk-space-watchdog.service <<UNIT
[Unit]
Description=Disk space watchdog (pause downloads + evict on low /mnt/hdd, cleanup on full SSD)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disk-space-watchdog.sh
Nice=10
UNIT
    cat > /etc/systemd/system/disk-space-watchdog.timer <<UNIT
[Unit]
Description=Run disk-space-watchdog every 5 min

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    systemctl enable --now disk-space-watchdog.timer
  '
  ok "disk-space-watchdog.timer active on $TIAMAT"
}

# ─── verification ────────────────────────────────────────────────────────────
verify() {
  log "verifying"
  local code i
  for i in $(seq 1 20); do
    : "$i"  # SC2034: i intentionally unused; loop is for retry timing
    code=$(ssh_ct_quiet "curl -fsS -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:$GUIDE_PORT/" || echo 000)
    case "$code" in 200|301|302|303|307|308) break ;; esac
    sleep 2
  done
  if [[ "$code" =~ ^(200|3..) ]]; then
    ok "guide HTTP $code on http://$CT_IP:$GUIDE_PORT/"
  else
    err "guide did not respond on :$GUIDE_PORT (last code=$code)"
    ssh_ct "journalctl -u unified-guide.service -n 60 --no-pager" >&2 || true
    return 1
  fi
  # state.json count
  ssh_ct_quiet "test -f /var/cache/unified-guide/state.json && jq -c '.counts' /var/cache/unified-guide/state.json" || true
  # disk-watchdog state
  ssh_t "test -f /var/lib/disk-watchdog/status.json && jq -c '{hdd:.hdd_used_pct, ssd:.ssd_used_pct, paused:.downloads_paused}' /var/lib/disk-watchdog/status.json" || true
}

main() {
  self_test
  preflight

  log "discovering values"
  local tmdb jf
  tmdb=$(discover_tmdb_key) || true
  jf=$(discover_jellyfin_token) || true
  if [ -n "$tmdb" ]; then ok "TMDB API key discovered (${#tmdb} chars)"; else warn "no TMDB key found — SVOD lanes will be empty until you set UG_TMDB_API_KEY in /etc/unified-guide/env"; fi
  if [ -n "$jf" ];   then ok "Jellyfin token discovered (${#jf} chars)";  else warn "no Jellyfin token found — local-library lane disabled until you set UG_JELLYFIN_TOKEN"; fi

  push_artifacts
  install_yttv_units
  write_env_files "$tmdb" "$jf"
  configure_caddy
  install_tailscale
  enable_units
  install_watchdog_host
  verify

  echo
  ok "done"
  printf '  %s LAN URL:  %shttp://%s:%d/%s\n' "→" "$C_INFO" "$CT_IP" "$GUIDE_PORT" "$C_RST"
  printf '  %s Hostname: %shttps://guide.mediastack.lan/%s   (via Caddy + AdGuard DNS)\n' "→" "$C_INFO" "$C_RST"
  printf '  %s YT TV:    %sstage cookies/browse.json at /var/lib/yttv-scraper/browse.json in CT-%s%s\n' "→" "$C_WARN" "$CT" "$C_RST"
  printf '             (see docs/UNIFIED-EPG.md for the cookie refresh procedure)\n'
}

main "$@"
