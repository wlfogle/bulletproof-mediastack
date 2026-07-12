#!/usr/bin/env bash
# =============================================================================
# setup-habridge-ct.sh — Self-healing HABridge (CT-501) rebuilder for Proxmox
# =============================================================================
# Recreates the CT-501 "habridge" LXC that was deleted, following the recipe in
# docs/VOICE-CONTROL.md. HABridge is a Java Philips-Hue emulator that lets
# Fire TV Alexa discover Home Assistant scripts as fake Hue lights.
#
# Verified facts (2026-07-12):
#   - No CT-501 vzdump backup exists -> full rebuild (not a restore).
#   - Current LAN gateway is the Archer at 192.168.12.254 (NOT .1 as the older
#     VOICE-CONTROL.md example shows). CT uses gw=192.168.12.254.
#   - .251 is free; debian-12 template present; net bridge vmbr0.
#   - HABridge -> HA REST needs a long-lived token; HA (.123) must be reachable
#     to arm the 9 devices. That token step is a documented follow-up.
#
# Run ON TIAMAT (Proxmox host) as root:
#   bash setup-habridge-ct.sh            # normal (idempotent / resumable)
#   bash setup-habridge-ct.sh --reset    # destroy CT-501 and rebuild fresh
# =============================================================================
set -Eeuo pipefail

# --- Config ------------------------------------------------------------------
CTID=501
HOSTNAME="habridge"
MEMORY=512
CORES=1
IP="192.168.12.251/24"
GW="192.168.12.254"
NAMESERVER="192.168.12.244"
HWADDR="BC:24:11:AB:A3:2D"
BRIDGE="vmbr0"
STORAGE="local-lvm"
ROOTFS_GB=4
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
HA_IP="192.168.12.123"
STATE_DIR="/var/lib/habridge-ct-setup"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="/var/log/habridge-ct-setup-${TS}.txt"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# --- Self-test ---------------------------------------------------------------
bash -n "$0" || { echo "FATAL: syntax error in $0"; exit 1; }
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$0" || log "[WARN] shellcheck warnings (non-fatal)"
fi

# --- ERR trap ----------------------------------------------------------------
trap '_err $LINENO "$BASH_COMMAND" $?' ERR
_err() {
  local line="$1" cmd="$2" code="$3"
  {
    echo "============================================================"
    echo "ERROR line ${line}: ${cmd} (exit ${code})"
    echo "FUNCNAME: ${FUNCNAME[*]:-main}"
    echo "--- df -h ---"; df -h
    echo "--- free -m ---"; free -m
    echo "--- pct status ${CTID} ---"; pct status "$CTID" 2>/dev/null || true
    echo "--- pct config ${CTID} ---"; pct config "$CTID" 2>/dev/null || true
    echo "--- last 40 journal ---"; journalctl -n 40 --no-pager 2>/dev/null || true
    echo "============================================================"
  } | tee -a "$LOG"
  echo "Failure log: $LOG"
}

# --- State helpers -----------------------------------------------------------
[[ "${1:-}" == "--reset" ]] && { log "RESET: destroying CT ${CTID} + state"; pct stop "$CTID" 2>/dev/null || true; pct destroy "$CTID" --purge 1 2>/dev/null || true; rm -rf "$STATE_DIR"; }
mkdir -p "$STATE_DIR"
done_step() { [[ -f "${STATE_DIR}/$1.done" ]]; }
mark_step() { touch "${STATE_DIR}/$1.done"; }

pexec() { pct exec "$CTID" -- bash -c "$1"; }

# --- Preflight ---------------------------------------------------------------
log "=== PREFLIGHT ==="
[[ $EUID -eq 0 ]] || { log "FATAL: must run as root on Tiamat"; exit 1; }
command -v pct   >/dev/null || { log "FATAL: pct not found (run on Proxmox host)"; exit 1; }
command -v pveam >/dev/null || { log "FATAL: pveam not found"; exit 1; }

# Template present? download if missing.
if ! pveam list local 2>/dev/null | grep -q "debian-12-standard_12.12-1_amd64.tar.zst"; then
  log "Template missing — downloading via pveam"
  pveam update || true
  pveam download local debian-12-standard_12.12-1_amd64.tar.zst
fi

# .251 must be free (unless it's our own CT already)
if ping -c1 -W1 192.168.12.251 >/dev/null 2>&1 && ! pct status "$CTID" >/dev/null 2>&1; then
  log "FATAL: 192.168.12.251 is answering but no CT ${CTID} exists — address in use elsewhere"; exit 1
fi

# Internet reachability for jar download
if ! curl -fsS --max-time 10 -o /dev/null https://api.github.com; then
  log "[WARN] api.github.com not reachable from host — CT download step may need retry"
fi

# HA reachability (informational — token step depends on it)
if curl -fsS --max-time 5 -o /dev/null "http://${HA_IP}:8123"; then
  log "HA ${HA_IP}:8123 reachable"
else
  log "[WARN] HA ${HA_IP}:8123 NOT reachable — device/token arming is a follow-up"
fi
log "Preflight OK"

# --- Step 1: create + start CT ----------------------------------------------
if ! done_step create; then
  if pct status "$CTID" >/dev/null 2>&1; then
    log "CT ${CTID} already exists — skipping create"
  else
    log "Creating CT ${CTID} (${HOSTNAME}) gw=${GW}"
    pct create "$CTID" "$TEMPLATE" \
      --hostname "$HOSTNAME" \
      --memory "$MEMORY" --cores "$CORES" \
      --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GW},hwaddr=${HWADDR}" \
      --nameserver "$NAMESERVER" \
      --storage "$STORAGE" --rootfs "${STORAGE}:${ROOTFS_GB}" \
      --unprivileged 1 --features nesting=1 \
      --onboot 1 --startup order=20 --start 1
  fi
  mark_step create
fi

# ensure running
if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
  log "Starting CT ${CTID}"; pct start "$CTID"
fi
for _ in $(seq 1 15); do pexec "true" 2>/dev/null && break; sleep 2; done
pexec "true" || { log "FATAL: CT ${CTID} not execable"; exit 1; }

# --- Step 2: install java + curl --------------------------------------------
if ! done_step packages; then
  log "Installing openjdk-17-jre-headless + curl"
  pexec "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y openjdk-17-jre-headless curl ca-certificates"
  pexec "java -version" || { log "FATAL: java not installed"; exit 1; }
  mark_step packages
fi

# --- Step 3: download ha-bridge.jar ------------------------------------------
if ! done_step jar; then
  log "Resolving + downloading latest ha-bridge.jar"
  pexec '
    set -e
    mkdir -p /opt/habridge/data
    cd /opt/habridge
    if [ ! -s ha-bridge.jar ]; then
      url=$(curl -fsSL https://api.github.com/repos/bwssytems/ha-bridge/releases/latest | grep -o "https://[^\"]*ha-bridge[^\"]*\.jar" | head -1)
      [ -n "$url" ] || url="https://github.com/bwssytems/ha-bridge/releases/latest/download/ha-bridge.jar"
      for a in 1 2 3; do curl -fL --max-time 120 -o ha-bridge.jar "$url" && break; sleep $((a*4)); done
    fi
    test -s ha-bridge.jar
  '
  mark_step jar
fi

# --- Step 4: seed config (serverPort 80) ------------------------------------
if ! done_step config; then
  log "Seeding habridge.config (serverPort 80, upnp addr ${IP%/*})"
  pexec 'cat > /opt/habridge/data/habridge.config <<JSON
{
  "serverPort": 80,
  "upnpConfigAddress": "192.168.12.251",
  "upnpDeviceDb": "data/device.db",
  "upnpConfigDb": "data/habridge.config",
  "numberoflogmessages": 500,
  "upnpStrict": true,
  "traceupnp": false
}
JSON'
  mark_step config
fi

# --- Step 5: systemd service -------------------------------------------------
if ! done_step service; then
  log "Installing systemd unit"
  pexec 'cat > /etc/systemd/system/habridge.service <<UNIT
[Unit]
Description=HABridge - Alexa Hue Emulation
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/habridge
ExecStart=/usr/bin/java -jar -Dconfig.file=/opt/habridge/data/habridge.config /opt/habridge/ha-bridge.jar
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable habridge
systemctl restart habridge'
  mark_step service
fi

# --- Step 6: positive verification ------------------------------------------
log "Verifying HABridge web UI on :80 ..."
ok=""
for _ in $(seq 1 20); do
  code=$(pexec "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:80/ || true")
  [[ "$code" =~ ^(200|302)$ ]] && { ok=1; break; }
  sleep 3
done
[[ -n "$ok" ]] || { log "FATAL: HABridge not responding on :80 inside CT"; pexec "systemctl status habridge --no-pager -l | tail -30" || true; exit 1; }

# reachable from LAN?
if curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://192.168.12.251/" | grep -qE '200|302'; then
  log "HABridge reachable on LAN at http://192.168.12.251"
else
  log "[WARN] :80 up inside CT but not answered over LAN yet (check ${BRIDGE}/gateway)"
fi

log "============================================================"
log "SUCCESS: CT-${CTID} habridge rebuilt and running"
log "  Web UI : http://192.168.12.251  (and http://habridge.tiamat.local via Caddy)"
log "  Service: pct exec ${CTID} -- systemctl status habridge"
log "FOLLOW-UP (blocked until HA ${HA_IP} reachable):"
log "  1) HA -> Profile -> create Long-Lived Token"
log "  2) Re-add the 9 Hue devices (script.movie_night, etc.) pointing at"
log "     http://${HA_IP}:8123 with that token (see docs/VOICE-CONTROL.md +"
log "     scripts/update-habridge-token.sh)"
log "  3) Fire TV: 'Alexa, discover devices'"
log "============================================================"
