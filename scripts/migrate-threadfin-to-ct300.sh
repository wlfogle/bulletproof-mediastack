#!/usr/bin/env bash
# migrate-threadfin-to-ct300.sh — fold CT-234 Threadfin into CT-300.
#
# Self-healing per AGENTS.md:
#   - bash -n + shellcheck self-test
#   - preflight: tiamat ssh, CT-234 + CT-300 running, :34400 free in CT-300
#   - verify-execute-heal per step, idempotent re-run
#   - on failure: dump diagnostics + roll back (re-enable CT-234 threadfin)
#   - end-to-end HTTP probe http://127.0.0.1:34400/web/
#
# Live source layout (verified before authoring):
#   CT-234 binary : /opt/threadfin/threadfin     (Go ELF, ~10 MB)
#   CT-234 config : /root/.threadfin/            (settings.json + auth + xepg)
#   CT-234 unit   : /etc/systemd/system/threadfin.service (Type=simple, port :34400)
#   CT-300 target : same paths inside CT-300, same unit, same port.

set -Eeuo pipefail

TIAMAT="${TIAMAT:-tiamat}"
SRC_CT="${SRC_CT:-234}"
DST_CT="${DST_CT:-300}"
PORT="${PORT:-34400}"
TS="$(date +%Y%m%d-%H%M%S)"
TAR_NAME="threadfin-migrate-${TS}.tgz"

C_INFO=$'\e[1;36m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_RST=$'\e[0m'
log()  { printf '%s[migrate-threadfin]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s[migrate-threadfin]%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '%s[migrate-threadfin]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s[migrate-threadfin]%s %s\n' "$C_ERR"  "$C_RST" "$*" >&2; }

ROLLBACK_NEEDED=0
on_err() {
  local rc=$? line=$1
  err "FAILED at line $line (exit $rc)"
  if [ "$ROLLBACK_NEEDED" = 1 ]; then
    warn "rolling back: re-enabling threadfin in CT-${SRC_CT}"
    ssh -o BatchMode=yes "$TIAMAT" "pct exec $SRC_CT -- bash -c 'systemctl enable --now threadfin || true'" || true
  fi
  warn "diagnostic dump:"
  ssh -o BatchMode=yes "$TIAMAT" "pct exec $DST_CT -- journalctl -u threadfin -n 80 --no-pager 2>/dev/null || true"
  exit "$rc"
}
trap 'on_err $LINENO' ERR

self_test() {
  log "self-test: bash -n + shellcheck"
  bash -n "${BASH_SOURCE[0]}"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "${BASH_SOURCE[0]}" || warn "shellcheck warnings (non-fatal)"
  else
    warn "shellcheck not installed locally; skipping"
  fi
}

ssh_t() { ssh -o ConnectTimeout=8 -o BatchMode=yes "$TIAMAT" "$@"; }
exec_ct() {
  # exec_ct <ctid> <bash script via stdin>
  local ct=$1
  ssh -o ConnectTimeout=15 -o BatchMode=yes "$TIAMAT" "pct exec $ct -- bash -s" <<<"$2"
}

preflight() {
  log "preflight"
  ssh_t true                           || { err "ssh $TIAMAT unreachable"; exit 2; }
  ssh_t "pct status $SRC_CT | grep -q running" || { err "CT-$SRC_CT not running"; exit 2; }
  ssh_t "pct status $DST_CT | grep -q running" || { err "CT-$DST_CT not running"; exit 2; }
  # Port 34400 must NOT be bound on CT-300 (unless threadfin is already migrated).
  if exec_ct "$DST_CT" "ss -tln | awk '{print \$4}' | grep -q \":${PORT}\$\"" 2>/dev/null; then
    # If it's already threadfin, treat as idempotent rerun.
    if exec_ct "$DST_CT" "systemctl is-active --quiet threadfin" 2>/dev/null; then
      ok "threadfin already active in CT-$DST_CT — rerun will re-verify only"
      RERUN=1
    else
      err "port :$PORT already bound in CT-$DST_CT by something other than threadfin"
      exit 2
    fi
  else
    RERUN=0
  fi
  ok "preflight ok (rerun=$RERUN)"
}

snapshot_src() {
  [ "$RERUN" = 1 ] && { log "snapshot_src: skipped (rerun)"; return 0; }
  log "snapshotting CT-$SRC_CT threadfin state"
  exec_ct "$SRC_CT" "
    set -e
    test -x /opt/threadfin/threadfin
    test -d /root/.threadfin
    test -f /etc/systemd/system/threadfin.service
    cd /
    tar -czf /tmp/${TAR_NAME} \
      opt/threadfin \
      root/.threadfin \
      etc/systemd/system/threadfin.service
    sha256sum /tmp/${TAR_NAME}
    test -s /tmp/${TAR_NAME}
  "
  ssh_t "pct pull $SRC_CT /tmp/${TAR_NAME} /tmp/${TAR_NAME}"
  ssh_t "test -s /tmp/${TAR_NAME} && sha256sum /tmp/${TAR_NAME}"
  ok "snapshot pulled to Tiamat:/tmp/${TAR_NAME}"
}

stop_src() {
  [ "$RERUN" = 1 ] && { log "stop_src: skipped (rerun)"; return 0; }
  log "stopping + disabling threadfin in CT-$SRC_CT"
  ROLLBACK_NEEDED=1
  exec_ct "$SRC_CT" "
    systemctl disable --now threadfin || true
    # heal: kill stragglers + remove pid/lock files
    pkill -9 -x threadfin 2>/dev/null || true
    rm -f /opt/threadfin/threadfin.lock /root/.threadfin/threadfin.pid 2>/dev/null || true
    systemctl is-active threadfin && exit 1 || true
  "
  ok "CT-$SRC_CT threadfin stopped"
}

push_to_dst() {
  [ "$RERUN" = 1 ] && { log "push_to_dst: skipped (rerun)"; return 0; }
  log "pushing tar to CT-$DST_CT and extracting"
  ssh_t "pct push $DST_CT /tmp/${TAR_NAME} /tmp/${TAR_NAME}"
  exec_ct "$DST_CT" "
    set -e
    cd /
    tar -xzf /tmp/${TAR_NAME}
    chmod 0755 /opt/threadfin/threadfin
    chown -R root:root /opt/threadfin /root/.threadfin
    chmod 0700 /root/.threadfin
    # Ensure unit is the one we expect (re-write to be safe)
    cat > /etc/systemd/system/threadfin.service <<'UNIT'
[Unit]
Description=Threadfin - M3U Proxy for Jellyfin Live TV
After=syslog.target network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/threadfin
ExecStart=/opt/threadfin/threadfin
TimeoutStopSec=20
KillMode=process
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
    rm -f /tmp/${TAR_NAME}
  "
  ok "CT-$DST_CT files in place"
}

start_dst() {
  log "starting threadfin in CT-$DST_CT"
  exec_ct "$DST_CT" "
    set -e
    systemctl daemon-reload
    systemctl reset-failed threadfin 2>/dev/null || true
    systemctl enable --now threadfin
  "
  # Verify
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if exec_ct "$DST_CT" "curl -fsS -o /dev/null -m 4 http://127.0.0.1:${PORT}/web/" 2>/dev/null; then
      ok "threadfin HTTP OK on CT-$DST_CT :${PORT}"
      ROLLBACK_NEEDED=0
      return 0
    fi
    sleep 2
  done
  err "threadfin did not answer HTTP on CT-$DST_CT :${PORT}"
  return 1
}

caddy_block() {
  log "ensuring Caddy block for threadfin.mediastack.lan"
  exec_ct "$DST_CT" "
    set -e
    if ! grep -q 'threadfin.mediastack.lan' /etc/caddy/Caddyfile 2>/dev/null; then
      cat >> /etc/caddy/Caddyfile <<'CADDY'

threadfin.mediastack.lan, threadfin.local {
    tls internal
    import headers
    reverse_proxy 127.0.0.1:${PORT}
}
CADDY
      caddy validate --config /etc/caddy/Caddyfile 2>/dev/null || true
      systemctl reload caddy 2>/dev/null || systemctl restart caddy
    fi
  "
  ok "Caddy block present"
}

refresh_unified_guide() {
  log "kicking unified-guide-refresh (best-effort)"
  exec_ct "$DST_CT" "
    if systemctl list-unit-files | grep -q unified-guide-refresh.service; then
      systemctl start unified-guide-refresh.service || true
    fi
  " || true
}

main() {
  self_test
  preflight
  snapshot_src
  stop_src
  push_to_dst
  start_dst
  caddy_block
  refresh_unified_guide
  ok "DONE — Threadfin now runs in CT-${DST_CT} on :${PORT}"
  ok "  LAN:    http://192.168.12.30:${PORT}/web/"
  ok "  HTTPS:  https://threadfin.mediastack.lan/"
  ok "CT-${SRC_CT} left running but threadfin disabled. Stop CT once verified: pct stop ${SRC_CT}"
}

main "$@"
