#!/bin/bash
# =============================================================================
# stack-watchdog.sh — self-healing watchdog for Tiamat media stack
# CT-300 consolidated architecture — all services live in CT-300
# =============================================================================
LOG=/var/log/stack-watchdog.log
exec >> "$LOG" 2>&1
echo "--- watchdog run $(date) ---"

CT=300
CT_IP=192.168.12.30

ct_running() { pct status "$1" 2>/dev/null | grep -q running; }
http_ok() {
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null)
  [ "$CODE" = "200" ] || [ "$CODE" = "301" ] || [ "$CODE" = "302" ] || \
  [ "$CODE" = "307" ] || [ "$CODE" = "401" ]
}
run_pct() {
  local secs=$1; shift
  timeout "$secs" pct exec "$@" 2>/dev/null
}
ensure_ct_running() {
  local id=$1 name=$2
  if ! ct_running "$id"; then
    echo "[CRIT] CT-$id ($name) not running — starting"
    timeout 20 pct start "$id" 2>/dev/null || true
    sleep 10
  fi
}

# Ensure CT-300 (mediastack) is up first
ensure_ct_running 300 mediastack

# Service health checks — all in CT-300
declare -A SERVICES=(
  ["jellyfin"]="http://${CT_IP}:8096"
  ["threadfin"]="http://${CT_IP}:34400/web"
  ["homarr"]="http://${CT_IP}:7575"
  ["unified-guide"]="http://${CT_IP}:7700"
  ["riven"]="http://${CT_IP}:3001"
  ["riven-frontend"]="http://${CT_IP}:3010"
  ["sportarr"]="http://${CT_IP}:1867"
)

for svc in "${!SERVICES[@]}"; do
  url="${SERVICES[$svc]}"
  if http_ok "$url"; then
    echo "[OK] $svc"
  else
    echo "[WARN] $svc down — restarting"
    run_pct 25 $CT -- systemctl restart "$svc" || true
    sleep 8
    if http_ok "$url"; then
      echo "[RECOVERED] $svc"
    else
      echo "[CRITICAL] $svc still down after restart"
    fi
  fi
done

echo "--- watchdog done $(date) ---"
