#!/bin/bash
# Media stack watchdog — CT-300 consolidated architecture
# Cron: */5 * * * * root /usr/local/bin/media-watchdog.sh
LOG="/var/log/media-watchdog.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

CT=300
CT_IP=192.168.12.30

declare -A CHECKS=(
  ["jellyfin"]="http://${CT_IP}:8096"
  ["threadfin"]="http://${CT_IP}:34400/web"
  ["homarr"]="http://${CT_IP}:7575"
  ["unified-guide"]="http://${CT_IP}:7700"
  ["riven"]="http://${CT_IP}:3001"
  ["riven-frontend"]="http://${CT_IP}:3010"
  ["sportarr"]="http://${CT_IP}:1867"
)

for svc in "${!CHECKS[@]}"; do
  url="${CHECKS[$svc]}"
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
  if [[ "$code" == "000" ]]; then
    echo "$(ts) ALERT: $svc (CT-${CT}) down — restarting" >> "$LOG"
    pct exec $CT -- systemctl restart "$svc" 2>/dev/null || true
    sleep 5
    code2=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
    if [[ "$code2" == "000" ]]; then
      echo "$(ts) CRITICAL: $svc still down after restart" >> "$LOG"
    else
      echo "$(ts) RECOVERED: $svc back up (${code2})" >> "$LOG"
    fi
  fi
done
