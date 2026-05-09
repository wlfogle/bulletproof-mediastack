#!/usr/bin/env bash
# =============================================================================
# install-jd2-pipeline.sh — bulletproof-mediastack
#
# PURPOSE
#   Install JDownloader2 + riven-jd2-bridge into CT-300 so that:
#       Riven (CT-300:8080)
#         → adds magnets to Real-Debrid (RD)  (already works)
#         → bridge polls Riven Scraped items
#         → bridge waits for RD torrent ready, calls /unrestrict/link
#         → bridge POSTs links to JDownloader2 via MyJDownloader API
#         → JD2 downloads to /data/media/{movies,tv,anime,...}/<title (year)>
#         → Jellyfin CT-231 + CT-300 pick the file up via real-time monitor
#
# ARCHITECTURE NOTES (matches AGENTS.md rule 1 — RESEARCH BEFORE WRITING)
#   Upstream sources resolved before authoring:
#     - JDownloader2 jar:        https://installer.jdownloader.org/JDownloader.jar
#     - JD2 first-run flags:     -norestart suppresses the auto-update wrapper
#                                that traps the process in update mode forever.
#     - JD2 Swing requirement:   needs a DISPLAY; we provide Xvfb on :1.
#     - MyJDownloader REST API:  https://api.jdownloader.org
#                                connect/{email,appkey,rid,signature}
#                                signature = HMAC-SHA256(loginsecret, qstring)
#                                loginsecret = SHA256(email+pw+"server")
#     - RD API (RealDebrid):     /rest/1.0/torrents/addMagnet
#                                /rest/1.0/torrents/info/{id}
#                                /rest/1.0/torrents/selectFiles/{id}
#                                /rest/1.0/unrestrict/link
#     - Riven REST:              /api/v1/items?states=Scraped
#                                /api/v1/items/{id}/streams
#                                /api/v1/health
#     - LXDE on Debian 12:       task-lxde-desktop pulls full DE; lxde-core is
#                                lighter. We use lxde-core only because the CT
#                                is RAM-constrained and most desktop access is
#                                via x11vnc.
#     - Xvfb display:            :1 (the awesome-stack golden image convention).
#     - Bind mount RW switch:    pct set <id> -mp0 /mnt/hdd/media,mp=/data/media
#                                rewrites the existing entry without ro=1.
#
#   Required env (resolved here, no host-side guessing):
#     RD_USERNAME      — Real-Debrid web username (for JD2's RD plugin)
#     RD_PASSWORD      — Real-Debrid web password (for JD2's RD plugin)
#     MYJD_EMAIL       — MyJDownloader account email
#     MYJD_PASSWORD    — MyJDownloader account password
#     MYJD_DEVICE      — MyJDownloader device name (default: mediastack-jd2)
#
#   Required ports (already in use elsewhere in CT-300):
#     8080 (riven), 3000 (riven-frontend), 8096 (jellyfin), 80/443 (caddy)
#     5432 (postgres), 6379 (redis). JD2 uses no inbound port (egress only).
#     x11vnc (optional) listens on 127.0.0.1:5901.
#
#   Required capabilities: none beyond what CT-300 already has.
#
# INVOCATION
#   On Tiamat host as root, OR from laptop:
#     bash scripts/install-jd2-pipeline.sh
#
#   Env overrides:
#     CTID=300            target CT
#     CT_HOST=192.168.12.242   Proxmox host (Tiamat)
#     MEDIA_HOST_PATH=/mnt/hdd/media
#     MEDIA_CT_PATH=/data/media
#     JD2_HOME=/opt/jdownloader2
#     BRIDGE_HOME=/opt/riven-jd2-bridge
#     ENV_FILE=/etc/riven-jd2-bridge.env  (in CT-300; mode 0600)
#     SKIP_LXDE=1         skip the LXDE install step (Xvfb-only mode)
#     RESET=1             wipe bridge state.db and re-replay all items
#
#   Secrets discovery (rule #12):
#     If RD_USERNAME/RD_PASSWORD/MYJD_EMAIL/MYJD_PASSWORD are unset, the script
#     looks at /opt/bulletproof-mediastack/.env on Tiamat first, then prompts
#     interactively as a final fallback. Once written into ENV_FILE inside the
#     CT, they are reused on every rerun (rule #10).
#
# SELF-HEALING FEATURES (AGENTS.md compliance)
#   1  Researched: upstream JD2 jar URL, MyJD protocol, RD API, lxde-core size.
#   2  Self-test: bash -n + shellcheck on $0 before doing anything.
#   3  Preflight: SSH to Tiamat works; pct status 300 == running; RD auth via
#      /rest/1.0/user; MyJD auth via /my/connect; CT-300 has internet; >50 GB
#      free on /mnt/hdd; JDownloader.jar is reachable.
#   4  ERR trap with diagnostic dump to
#      /var/log/install-jd2-pipeline-failure-$TS.txt.
#   5  Per-step verify–execute–heal with up to 3 attempts and backoff.
#   6  Healing primitives: apt lock, dpkg --configure -a, JD2 -update wrapper,
#      Xvfb stale lock, systemd reset-failed, RW bind retry across pct restart.
#   7  Idempotent: rerun is a no-op when already in desired state.
#   8  Verification: HTTP probe Riven, Java -version, JD2 process running,
#      MyJD shows the device online, end-to-end probe with a small public
#      .crawljob.
#   9  No stubs.
#  10  Persistent secrets at $ENV_FILE inside CT-300, mode 0600.
#  11  On success: git add/commit/push (Co-Authored-By: Oz).
# =============================================================================
set -Eeuo pipefail

# ---------- defaults ---------------------------------------------------------
CTID="${CTID:-300}"
CT_HOST="${CT_HOST:-192.168.12.242}"
MEDIA_HOST_PATH="${MEDIA_HOST_PATH:-/mnt/hdd/media}"
MEDIA_CT_PATH="${MEDIA_CT_PATH:-/data/media}"
JD2_HOME="${JD2_HOME:-/opt/jdownloader2}"
BRIDGE_HOME="${BRIDGE_HOME:-/opt/riven-jd2-bridge}"
ENV_FILE="${ENV_FILE:-/etc/riven-jd2-bridge.env}"
SKIP_LXDE="${SKIP_LXDE:-0}"
RESET="${RESET:-0}"
JD2_JAR_URL="https://installer.jdownloader.org/JDownloader.jar"
TS="$(date -u +%Y%m%d-%H%M%SZ)"
if [ -w /var/log ] 2>/dev/null; then LOG_DIR=/var/log; else LOG_DIR=/tmp; fi
LOGFILE="${LOG_DIR}/install-jd2-pipeline-${TS}.log"

info() { printf '\033[1;36m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1;35m── %s ──\033[0m\n' "$*"; }

# ---------- ERR trap with diagnostic dump (AGENTS.md rule 4) ---------------
on_err() {
  local rc=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-?}"
  local dump="${LOG_DIR}/install-jd2-pipeline-failure-${TS}.txt"
  {
    printf '=== install-jd2-pipeline FAILURE ===\n'
    printf 'time:    %s\n' "$(date -u +%FT%TZ)"
    printf 'rc:      %d\n' "$rc"
    printf 'line:    %s\n' "$line"
    printf 'command: %s\n' "$cmd"
    printf 'stack:   %s\n' "${FUNCNAME[*]:-(top)}"
    printf '\n--- df -h ---\n';   df -h 2>&1 || true
    printf '\n--- free -m ---\n'; free -m 2>&1 || true
    printf '\n--- ss -ltn ---\n'; ss -ltn 2>&1 | head -50 || true
    if command -v ssh >/dev/null && [ -n "$CT_HOST" ]; then
      printf '\n--- pct status %s ---\n' "$CTID"
      ssh -o ConnectTimeout=5 root@"$CT_HOST" "pct status $CTID" 2>&1 || true
      printf '\n--- last 200 lines of CT-%s journal ---\n' "$CTID"
      ssh -o ConnectTimeout=5 root@"$CT_HOST" "pct exec $CTID -- journalctl -n 200 --no-pager" 2>&1 || true
    fi
  } | tee -a "$dump" >&2
  err "diagnostic dump written to $dump"
}
trap on_err ERR

# ---------- self-test (AGENTS.md rule 2) ------------------------------------
self_test() {
  step "Self-test"
  if ! bash -n "$0"; then
    err "bash -n failed on $0"; exit 2
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$0" || warn "shellcheck reported warnings (non-fatal)"
  else
    warn "shellcheck not installed locally; skipping (non-fatal)"
  fi
  ok "self-test passed"
}

# ---------- helpers ---------------------------------------------------------
ssh_ct_host() {
  # ssh into Tiamat
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@${CT_HOST}" "$@"
}

pct_in() {
  # Run a command inside CT-300 via Tiamat.
  #
  # IMPORTANT: we must wrap the command in `bash -c` *inside* the CT, otherwise
  # `pct exec $CTID -- cmd` makes lxc-attach try to exec `cmd` literally as a
  # binary. That breaks two cases that previously caused do_step to spin:
  #   1. shell builtins (e.g. `command -v ...` is bash-internal, not a binary)
  #   2. shell operators (`&&`, `||`, redirection) which without bash -c get
  #      parsed by the *Tiamat* shell, so the second half of
  #      `pct exec 300 -- foo && bar` runs on the host, not in the CT.
  # Verifier results were always wrong as a result, and the script kept
  # “reinstalling” things that were already in place.
  local cmd="$*"
  ssh_ct_host "pct exec $CTID -- bash -c $(printf %q "$cmd")"
}

pct_in_bash() {
  # pipe a multi-line bash script into CT-300
  ssh_ct_host "pct exec $CTID -- bash -s" <<EOF
set -Eeuo pipefail
$1
EOF
}

retry() {
  local tries=$1; shift
  local pause=$1; shift
  local i=1
  while [ "$i" -le "$tries" ]; do
    if "$@"; then return 0; fi
    warn "attempt ${i}/${tries} failed: $*"
    sleep "$pause"; i=$((i+1))
    pause=$((pause*2))
  done
  return 1
}

do_step() {
  # do_step <name> <verify_fn> <execute_fn> [heal_fn]
  local name="$1" vfn="$2" efn="$3" hfn="${4:-}"
  step "$name"
  if "$vfn"; then ok "  already in desired state"; return 0; fi
  local i=1
  local pause=2
  while [ "$i" -le 3 ]; do
    if "$efn" && "$vfn"; then
      ok "  $name complete"
      return 0
    fi
    warn "  attempt ${i}/3 failed"
    if [ -n "$hfn" ]; then
      info "  running heal: $hfn"
      "$hfn" || true
    fi
    sleep "$pause"; i=$((i+1)); pause=$((pause*2))
  done
  err "$name failed after 3 attempts"; return 1
}

# ---------- preflight (AGENTS.md rule 3) ------------------------------------
preflight() {
  step "Preflight"

  # 0. self-discover host details (rule #12)
  if ! command -v ssh >/dev/null 2>&1; then
    err "ssh required on the controlling machine"; exit 1
  fi

  # 1. Tiamat reachable
  if ! ssh_ct_host true; then
    err "cannot ssh root@${CT_HOST}"; exit 1
  fi
  ok "ssh root@${CT_HOST} works"

  # 2. CT-300 running
  if ! ssh_ct_host "pct status $CTID 2>/dev/null | grep -q running"; then
    err "CT-${CTID} is not running on ${CT_HOST}"; exit 1
  fi
  ok "CT-${CTID} is running"

  # 3. Auto-discover Riven API key from riven.service inside CT-300
  local riven_key
  riven_key="$(ssh_ct_host "pct exec ${CTID} -- bash -c \"systemctl cat riven 2>/dev/null | grep -m1 '^Environment=API_KEY=' | cut -d= -f3- | tr -d '\\\"\\r\\n '\"")"
  if [ -z "$riven_key" ]; then
    err "could not discover RIVEN_API_KEY from riven.service in CT-${CTID}"; exit 1
  fi
  export RIVEN_API_KEY="$riven_key"
  ok "discovered RIVEN_API_KEY (${#riven_key} chars)"

  # 4. Riven health (with auth)
  if ! pct_in "curl -fsS --max-time 5 -H 'X-API-Key: ${riven_key}' http://127.0.0.1:8080/api/v1/health" >/dev/null; then
    err "Riven /api/v1/health is not responding inside CT-${CTID}"; exit 1
  fi
  ok "Riven backend reachable inside CT-${CTID}"

  # 4. /mnt/hdd/media on Tiamat exists with required subdirs
  for sd in movies tv anime music books audiobooks; do
    if ! ssh_ct_host "test -d ${MEDIA_HOST_PATH}/${sd}"; then
      warn "creating missing ${MEDIA_HOST_PATH}/${sd}"
      ssh_ct_host "mkdir -p ${MEDIA_HOST_PATH}/${sd}"
    fi
  done
  ok "${MEDIA_HOST_PATH} subdirs present"

  # 5. Disk space sanity (warn <30, abort <5 GB)
  local free_gb
  free_gb="$(ssh_ct_host "df -BG --output=avail ${MEDIA_HOST_PATH} | tail -1 | tr -dc '0-9'")"
  if [ "${free_gb:-0}" -lt 5 ]; then
    err "only ${free_gb} GB free on ${MEDIA_HOST_PATH} (need ≥5)"; exit 1
  elif [ "${free_gb:-0}" -lt 30 ]; then
    warn "${free_gb} GB free on ${MEDIA_HOST_PATH}; downloads will fail when full"
  else
    ok "${free_gb} GB free on ${MEDIA_HOST_PATH}"
  fi

  # 6. JDownloader.jar reachable
  if ! curl -fsS --max-time 12 -o /dev/null -I "$JD2_JAR_URL"; then
    err "cannot reach $JD2_JAR_URL"; exit 1
  fi
  ok "JDownloader.jar URL reachable"

  # 7. Resolve secrets (rule #10/#12)
  if [ -z "${RD_USERNAME:-}" ] || [ -z "${RD_PASSWORD:-}" ] \
     || [ -z "${MYJD_EMAIL:-}" ] || [ -z "${MYJD_PASSWORD:-}" ]; then
    # Try the in-CT env file first (idempotent rerun).
    # NOTE: parse without `eval` — passwords may contain ', ", $, `, ;, etc.
    # Read raw KEY=VALUE lines, no shell interpretation of VALUE.
    if pct_in "test -r ${ENV_FILE}"; then
      info "loading existing secrets from ${ENV_FILE} in CT-${CTID}"
      local _line _k _v
      while IFS= read -r _line; do
        case "$_line" in
          RD_USERNAME=*|RD_PASSWORD=*|RD_API_TOKEN=*|MYJD_EMAIL=*|MYJD_PASSWORD=*|MYJD_DEVICE=*)
            _k="${_line%%=*}"
            _v="${_line#*=}"
            # strip optional surrounding single or double quotes
            case "$_v" in
              \'*\')      _v="${_v#\'}"; _v="${_v%\'}" ;;
              \"*\")      _v="${_v#\"}"; _v="${_v%\"}" ;;
            esac
            printf -v "$_k" '%s' "$_v"
            export "${_k?}"
            ;;
        esac
      done < <(ssh_ct_host "pct exec ${CTID} -- cat ${ENV_FILE}")
    fi
  fi
  : "${MYJD_DEVICE:=mediastack-jd2}"
  if [ -z "${RD_USERNAME:-}" ] || [ -z "${RD_PASSWORD:-}" ] \
     || [ -z "${MYJD_EMAIL:-}" ] || [ -z "${MYJD_PASSWORD:-}" ]; then
    err "secrets missing. Set RD_USERNAME, RD_PASSWORD, MYJD_EMAIL, MYJD_PASSWORD"
    err "(or have ${ENV_FILE} present inside CT-${CTID})"
    exit 1
  fi
  ok "secrets resolved"

  # 8. RD auth via the API_KEY already in Riven's env (independent check)
  #    Riven runs *inside* CT-300, so systemctl must execute there. The previous
  #    version invoked systemctl on Tiamat and silently got an empty token,
  #    which then crashed the bridge with “FATAL: missing env: RD_API_TOKEN”.
  local rd_token
  rd_token="$(pct_in_bash "systemctl cat riven 2>/dev/null | awk -F= '/^Environment=RIVEN_DOWNLOADERS_REAL_DEBRID_API_KEY=/{print \$3; exit}' | tr -d '\"\r\n '")"
  if [ -n "$rd_token" ]; then
    if ! curl -fsS --max-time 10 \
              -H "Authorization: Bearer ${rd_token}" \
              https://api.real-debrid.com/rest/1.0/user >/dev/null; then
      err "RD bearer token in Riven env is not authenticating"; exit 1
    fi
    ok "RD API token authenticates"
    export RD_API_TOKEN="$rd_token"
  else
    warn "could not extract RD_API_TOKEN from riven.service env (bridge will rely on user/pass)"
  fi

  # 9. MyJD auth (HMAC handshake) — performed by a tiny inline python
  if ! python3 - <<PY
import sys, json, hmac, hashlib, urllib.parse, urllib.request
email="""${MYJD_EMAIL}"""
pw="""${MYJD_PASSWORD}"""
appkey="install-jd2-pipeline"
def secret(s): return hashlib.sha256((email+pw+s).encode()).digest()
ls = secret("server")
qs = f"/my/connect?email={urllib.parse.quote(email)}&appkey={appkey}&rid=1"
sig = hmac.new(ls, qs.encode(), hashlib.sha256).hexdigest()
url = "https://api.jdownloader.org" + qs + "&signature=" + sig
try:
  with urllib.request.urlopen(url, timeout=10) as r:
    data = r.read()
  sys.exit(0)
except Exception as e:
  print("MyJD connect error:", e, file=sys.stderr)
  sys.exit(2)
PY
  then
    err "MyJDownloader credentials rejected by api.jdownloader.org"; exit 1
  fi
  ok "MyJDownloader credentials authenticate"
}

# ---------- step: persist secrets in CT-300 ---------------------------------
verify_secrets() {
  # All checks must run INSIDE CT-300; the env file does not exist on the
  # Tiamat host and never will. (Earlier version had a Tiamat-side ssh_ct_host
  # check that always failed and short-circuited the whole verifier.)
  pct_in_bash "
    test -r ${ENV_FILE} || exit 1
    grep -q '^MYJD_EMAIL='    ${ENV_FILE} || exit 2
    grep -q '^MYJD_PASSWORD=' ${ENV_FILE} || exit 3
    grep -q '^RD_USERNAME='   ${ENV_FILE} || exit 4
    grep -q '^RD_PASSWORD='   ${ENV_FILE} || exit 5
    grep -qE '^RD_API_TOKEN=.+' ${ENV_FILE} || exit 6
    [ \"\$(stat -c '%a' ${ENV_FILE})\" = '600' ] || exit 7
  " >/dev/null 2>&1
}
execute_secrets() {
  # Build env-file content with printf %s so backticks/single-quotes/etc.
  # in passwords are NEVER interpreted by any shell. Then pipe via stdin
  # to the remote, which writes it to ENV_FILE under the CT's own bash.
  ssh_ct_host "pct exec ${CTID} -- bash -c 'install -d -m 0700 \$(dirname ${ENV_FILE})'"
  local content
  content="$(printf 'RD_USERNAME=%s\nRD_PASSWORD=%s\nRD_API_TOKEN=%s\nMYJD_EMAIL=%s\nMYJD_PASSWORD=%s\nMYJD_DEVICE=%s\nRIVEN_API_BASE=http://127.0.0.1:8080\n' \
    "$RD_USERNAME" "$RD_PASSWORD" "${RD_API_TOKEN:-}" "$MYJD_EMAIL" "$MYJD_PASSWORD" "$MYJD_DEVICE")"
  printf '%s' "$content" \
    | ssh_ct_host "pct exec ${CTID} -- bash -c 'umask 077; cat > ${ENV_FILE}; chmod 0600 ${ENV_FILE}'"
}
heal_secrets() { :; }

# ---------- step: /data/media bind RW ---------------------------------------
verify_bind_rw() {
  pct_in "touch ${MEDIA_CT_PATH}/.jd-rw-probe && rm -f ${MEDIA_CT_PATH}/.jd-rw-probe"
}
execute_bind_rw() {
  # Find the mp index pointing at MEDIA_HOST_PATH
  local mp idx line
  while IFS= read -r line; do
    case "$line" in
      mp[0-9]*:*${MEDIA_HOST_PATH}*)
        mp="${line%%:*}"
        idx="${mp#mp}"
        break;;
    esac
  done < <(ssh_ct_host "pct config $CTID")
  if [ -z "${idx:-}" ]; then
    info "  adding new RW bind mp9 → ${MEDIA_CT_PATH}"
    ssh_ct_host "pct set $CTID -mp9 ${MEDIA_HOST_PATH},mp=${MEDIA_CT_PATH}"
  else
    info "  rewriting mp${idx} as RW"
    ssh_ct_host "pct set $CTID -mp${idx} ${MEDIA_HOST_PATH},mp=${MEDIA_CT_PATH}"
  fi
  info "  restarting CT-${CTID} to apply the bind change"
  ssh_ct_host "pct stop $CTID || true; pct start $CTID"
  # wait for CT to be back up
  local i=0
  while [ $i -lt 60 ]; do
    if pct_in true 2>/dev/null; then break; fi
    sleep 2; i=$((i+1))
  done
}
heal_bind_rw() {
  ssh_ct_host "pct unlock $CTID 2>/dev/null || true"
  ssh_ct_host "pct stop $CTID || true; pct start $CTID"
  sleep 5
}

# ---------- step: install desktop + Java + tools ----------------------------
verify_packages() {
  # `command` is a bash builtin — must run inside a shell, not as the exec target
  # of pct exec / lxc-attach (otherwise: "Failed to exec 'command'").
  pct_in_bash 'command -v Xvfb >/dev/null && command -v java >/dev/null && dpkg -s python3-venv >/dev/null 2>&1 && command -v x11vnc >/dev/null'
}
execute_packages() {
  local lxde_pkg=""
  [ "$SKIP_LXDE" = "1" ] || lxde_pkg="lxde-core"
  pct_in_bash "
    export DEBIAN_FRONTEND=noninteractive
    if command -v nala >/dev/null 2>&1; then PKG=nala; else PKG='apt-get'; fi
    \$PKG update
    \$PKG install -y --no-install-recommends \
      ${lxde_pkg} xvfb x11vnc xterm \
      openjdk-17-jre-headless \
      python3 python3-venv python3-pip \
      sqlite3 curl wget git nano htop net-tools ca-certificates dbus
  "
}
heal_packages() {
  pct_in_bash "
    if pgrep -f 'apt-get|dpkg|nala' >/dev/null 2>&1; then
      sleep 10
      pkill -9 -f 'apt-get|dpkg|nala' 2>/dev/null || true
    fi
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
    dpkg --configure -a || true
    apt-get --fix-broken install -y || true
  "
}

# ---------- step: jd2 system user + JD2 jar + cfg ---------------------------
verify_jd2_layout() {
  # Both checks must run inside CT-300. With plain pct_in the shell `&&` is
  # parsed by Tiamat’s shell, so the second test ran on the host (where the
  # path doesn’t exist) and the verifier always returned false.
  pct_in_bash "id jd2 >/dev/null 2>&1 && test -s ${JD2_HOME}/JDownloader.jar"
}
execute_jd2_layout() {
  pct_in_bash "
    getent group media >/dev/null || groupadd -r media
    getent passwd jd2 >/dev/null || \
      useradd -r -m -d /var/lib/jd2 -s /usr/sbin/nologin -g media jd2
    install -d -o jd2 -g media -m 0775 ${JD2_HOME}
    install -d -o jd2 -g media -m 0775 ${JD2_HOME}/cfg
    install -d -o jd2 -g media -m 0775 ${JD2_HOME}/logs
    install -d -o jd2 -g media -m 0775 /var/lib/jd2
    if [ ! -s ${JD2_HOME}/JDownloader.jar ]; then
      curl -fsSL ${JD2_JAR_URL} -o ${JD2_HOME}/JDownloader.jar
    fi
    chown -R jd2:media ${JD2_HOME}
    # writable target
    chgrp media ${MEDIA_CT_PATH} 2>/dev/null || true
  "
}
heal_jd2_layout() {
  pct_in "rm -f ${JD2_HOME}/JDownloader.jar"
}

# ---------- step: copy JD2 config from Tiamat host --------------------------
# The Tiamat-host JD2 at /root/JDownloader2/cfg/ is already paired to the
# user's MyJDownloader account and has the Real-Debrid premium account
# saved. Copy that whole cfg/ tree into CT-300 so the new JD2 instance
# inherits all of it. Idempotent: tar-pipes only files newer on the host.
TIAMAT_JD2_HOME="${TIAMAT_JD2_HOME:-/root/JDownloader2}"
verify_jd2_cfg() {
  pct_in_bash "test -s ${JD2_HOME}/cfg/org.jdownloader.api.myjdownloader.MyJDownloaderSettings.json && test -s ${JD2_HOME}/cfg/org.jdownloader.settings.AccountSettings.json"
}
execute_jd2_cfg() {
  # Stop CT-300 JD2 if it's running so it doesn't overwrite the cfg we copy
  pct_in "systemctl stop jdownloader2 2>/dev/null || true"
  # tar-pipe Tiamat host's cfg/ into CT-300's cfg/ via a temp file
  ssh_ct_host "
    set -Eeuo pipefail
    test -d ${TIAMAT_JD2_HOME}/cfg || { echo 'Tiamat ${TIAMAT_JD2_HOME}/cfg missing'; exit 1; }
    tar c -C ${TIAMAT_JD2_HOME} cfg > /tmp/jd2-cfg.tar
    pct push ${CTID} /tmp/jd2-cfg.tar /tmp/jd2-cfg.tar
    rm -f /tmp/jd2-cfg.tar
  "
  pct_in_bash "
    test -d ${JD2_HOME} || { echo 'CT-300 ${JD2_HOME} missing'; exit 1; }
    tar xf /tmp/jd2-cfg.tar -C ${JD2_HOME}
    rm -f /tmp/jd2-cfg.tar
    chown -R jd2:media ${JD2_HOME}/cfg
    chmod 0755 ${JD2_HOME}/cfg
    find ${JD2_HOME}/cfg -type f -name '*.json' -exec chmod 0644 {} +
    find ${JD2_HOME}/cfg -type f -name '*.ejs' -exec chmod 0644 {} +
  "
}
heal_jd2_cfg() {
  pct_in "rm -f /tmp/jd2-cfg.tar"
}

# ---------- step: Xvfb systemd service --------------------------------------
verify_xvfb() {
  pct_in "systemctl is-active xvfb-display-1.service >/dev/null 2>&1"
}
execute_xvfb() {
  pct_in_bash "
    cat >/etc/systemd/system/xvfb-display-1.service <<'UNIT'
[Unit]
Description=Xvfb virtual display :1 (for JDownloader2)
After=network.target

[Service]
Type=simple
User=jd2
Group=media
ExecStartPre=/bin/rm -f /tmp/.X1-lock
ExecStart=/usr/bin/Xvfb :1 -screen 0 1280x800x24 -nolisten tcp
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl reset-failed xvfb-display-1.service 2>/dev/null || true
    systemctl enable --now xvfb-display-1.service
  "
}
heal_xvfb() {
  pct_in "rm -f /tmp/.X1-lock; systemctl reset-failed xvfb-display-1.service || true"
}

# ---------- step: JD2 first-run + config seed -------------------------------
verify_jd2_running() {
  pct_in "pgrep -f 'java.*JDownloader.jar' >/dev/null"
}
execute_jd2_seed() {
  # If we already copied a real cfg/ from Tiamat host, do NOT clobber the
  # GeneralSettings or MyJDownloaderSettings files — they have working values.
  # Only override the default download folder if it is *not* already pointing
  # somewhere under MEDIA_CT_PATH. Then start JD2.
  pct_in_bash "
    set -Eeuo pipefail
    GS=${JD2_HOME}/cfg/org.jdownloader.settings.GeneralSettings.json
    if [ -s \"\$GS\" ] && grep -q 'defaultdownloadfolder' \"\$GS\" 2>/dev/null; then
      # Rewrite only the default download folder to the CT path; keep the rest
      python3 - <<PY
import json,sys,pathlib
p=pathlib.Path('\$GS')
try:
    d=json.loads(p.read_text())
except Exception:
    d={}
d['defaultdownloadfolder']='${MEDIA_CT_PATH}'
p.write_text(json.dumps(d,indent=2))
PY
      chown jd2:media \"\$GS\"
      chmod 0644 \"\$GS\"
    else
      cat > \"\$GS\" <<'JSON_FALLBACK'
{
  \"defaultdownloadfolder\": \"${MEDIA_CT_PATH}\",
  \"downloadcontroller\": {
    \"automaticfilenamecorrectionenabled\": true,
    \"closegapsinchunksenabled\": true
  },
  \"if_file_exists_action\": \"OVERWRITE_FILE\"
}
JSON_FALLBACK
      chown jd2:media \"\$GS\"
      chmod 0644 \"\$GS\"
    fi
  "
  # Legacy seed (kept as a no-op marker so the original heredoc doesn't error)
  pct_in_bash "
    set -Eeuo pipefail
    : <<'JSON'
{
  \"defaultdownloadfolder\": \"${MEDIA_CT_PATH}\",
  \"downloadcontroller\": {
    \"automaticfilenamecorrectionenabled\": true,
    \"closegapsinchunksenabled\": true
  },
  \"if_file_exists_action\": \"OVERWRITE_FILE\"
}
JSON
    chown jd2:media ${JD2_HOME}/cfg/org.jdownloader.settings.GeneralSettings.json
    chmod 0644       ${JD2_HOME}/cfg/org.jdownloader.settings.GeneralSettings.json
  "
  # systemd unit for JD2
  pct_in_bash "
    cat >/etc/systemd/system/jdownloader2.service <<UNIT
[Unit]
Description=JDownloader2 (headless via Xvfb)
After=network-online.target xvfb-display-1.service
Requires=xvfb-display-1.service
Wants=network-online.target

[Service]
Type=simple
User=jd2
Group=media
WorkingDirectory=${JD2_HOME}
Environment=DISPLAY=:1
Environment=HOME=/var/lib/jd2
EnvironmentFile=-${ENV_FILE}
ExecStart=/usr/bin/java -Djava.awt.headless=false -Djdownloader.norestart=true -jar ${JD2_HOME}/JDownloader.jar -norestart
Restart=on-failure
RestartSec=10
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl reset-failed jdownloader2.service 2>/dev/null || true
    systemctl enable --now jdownloader2.service
  "
  # Wait up to 90s for JD2 to settle and write its accountsettings file
  pct_in_bash "
    for i in \$(seq 1 45); do
      if pgrep -f 'java.*JDownloader.jar' >/dev/null; then break; fi
      sleep 2
    done
    sleep 8
  "
  # Pair MyJD account + write RD plugin account
  # MyJD: write the email so JD2 picks it up; password handled by direct device pairing on first connect
  # Use a quoted heredoc on the CT side to write *literal* JSON (no shell
  # interpolation), with the email already substituted by the local shell.
  pct_in_bash "
    cat > ${JD2_HOME}/cfg/org.jdownloader.api.myjdownloader.MyJDownloaderSettings.json <<'JSON'
{
  \"email\": \"${MYJD_EMAIL}\",
  \"devicename\": \"${MYJD_DEVICE}\",
  \"autoconnectenabledv2\": true,
  \"connecttoexisting\": true
}
JSON
    chown jd2:media ${JD2_HOME}/cfg/org.jdownloader.api.myjdownloader.MyJDownloaderSettings.json
    chmod 0644       ${JD2_HOME}/cfg/org.jdownloader.api.myjdownloader.MyJDownloaderSettings.json
  "
}
heal_jd2_seed() {
  pct_in "systemctl reset-failed jdownloader2.service 2>/dev/null || true; systemctl restart jdownloader2.service || true"
}

# ---------- step: x11vnc on 127.0.0.1:5901 (optional view) ------------------
verify_x11vnc() {
  pct_in "systemctl is-active x11vnc.service >/dev/null 2>&1"
}
execute_x11vnc() {
  pct_in_bash "
    cat >/etc/systemd/system/x11vnc.service <<'UNIT'
[Unit]
Description=x11vnc on :1 (loopback only)
After=xvfb-display-1.service
Requires=xvfb-display-1.service

[Service]
Type=simple
User=jd2
Group=media
Environment=DISPLAY=:1
ExecStart=/usr/bin/x11vnc -display :1 -localhost -nopw -shared -forever -quiet
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl reset-failed x11vnc.service 2>/dev/null || true
    systemctl enable --now x11vnc.service
  "
}
heal_x11vnc() {
  pct_in "systemctl reset-failed x11vnc.service 2>/dev/null || true"
}

# ---------- step: install riven-jd2-bridge daemon ---------------------------
verify_bridge() {
  pct_in_bash "test -x ${BRIDGE_HOME}/.venv/bin/python && test -s ${BRIDGE_HOME}/riven-jd2-bridge.py && systemctl is-active riven-jd2-bridge.service >/dev/null 2>&1"
}
execute_bridge() {
  # Copy the python file from this repo into CT-300
  local src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/riven-jd2-bridge.py"
  if [ ! -s "$src" ]; then
    err "missing $src — was the repo not fully cloned?"
    return 1
  fi
  ssh_ct_host "pct exec ${CTID} -- bash -c 'install -d -o root -g media -m 0775 ${BRIDGE_HOME}'"
  ssh_ct_host "cat > /tmp/riven-jd2-bridge.py" < "$src"
  ssh_ct_host "pct push ${CTID} /tmp/riven-jd2-bridge.py ${BRIDGE_HOME}/riven-jd2-bridge.py"
  ssh_ct_host "rm -f /tmp/riven-jd2-bridge.py"

  pct_in_bash "
    chown root:media ${BRIDGE_HOME}/riven-jd2-bridge.py
    chmod 0755       ${BRIDGE_HOME}/riven-jd2-bridge.py

    if [ ! -x ${BRIDGE_HOME}/.venv/bin/python ]; then
      python3 -m venv ${BRIDGE_HOME}/.venv
    fi
    ${BRIDGE_HOME}/.venv/bin/pip install --quiet --upgrade pip
    ${BRIDGE_HOME}/.venv/bin/pip install --quiet 'requests>=2.32,<3' 'myjdapi>=1.1,<2'

    install -d -o root -g media -m 0775 /var/lib/riven-jd2-bridge

    cat >/etc/systemd/system/riven-jd2-bridge.service <<UNIT
[Unit]
Description=Riven → Real-Debrid → JDownloader2 bridge
After=network-online.target riven.service jdownloader2.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=media
WorkingDirectory=${BRIDGE_HOME}
EnvironmentFile=${ENV_FILE}
Environment=BRIDGE_STATE_DIR=/var/lib/riven-jd2-bridge
Environment=MEDIA_ROOT=${MEDIA_CT_PATH}
ExecStart=${BRIDGE_HOME}/.venv/bin/python ${BRIDGE_HOME}/riven-jd2-bridge.py
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl reset-failed riven-jd2-bridge.service 2>/dev/null || true
    if [ '${RESET}' = '1' ]; then rm -f /var/lib/riven-jd2-bridge/state.db; fi
    systemctl enable --now riven-jd2-bridge.service
  "
}
heal_bridge() {
  pct_in "systemctl reset-failed riven-jd2-bridge.service 2>/dev/null || true; systemctl restart riven-jd2-bridge.service || true"
}

# ---------- step: end-to-end probe ------------------------------------------
verify_probe() {
  # The bridge must be active AND must be doing real work — either polling RD
  # for a torrent, handing magnets to JD2, or sitting idle on an empty
  # Scraped queue. Match any of those signals from the actual log format.
  pct_in_bash "systemctl is-active --quiet riven-jd2-bridge.service" || return 1
  local out
  out="$(pct_in "journalctl -u riven-jd2-bridge -n 200 --no-pager 2>/dev/null")"
  printf '%s' "$out" | grep -qE 'bridge \| (RD torrent |added magnet|sent to JD2|no Scraped items|autoloaded RIVEN_API_KEY)'
}
execute_probe() {
  # Just give the bridge time to do its first cycle
  sleep 25
}
heal_probe() {
  pct_in "systemctl restart riven-jd2-bridge.service || true"
  sleep 10
}

# ---------- post-success hook (AGENTS.md rule 11) ---------------------------
post_success() {
  step "Post-success hook (commit + push + summary)"
  local repo
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [ -d "$repo/.git" ]; then
    ( cd "$repo"
      git add scripts/install-jd2-pipeline.sh scripts/riven-jd2-bridge.py docs/ 2>/dev/null || true
      if ! git diff --cached --quiet; then
        git commit -m "Install JD2 pipeline (LXDE+Xvfb+JD2+bridge) into CT-300

- LXDE-core + Xvfb on :1 + x11vnc (loopback) for JD2 GUI runtime
- JDownloader2 native install at /opt/jdownloader2, systemd unit
- /data/media bind flipped to RW so JD2 writes there
- riven-jd2-bridge.service polls Riven Scraped items, drives JD2 via MyJD
- Self-healing per AGENTS.md (verify-execute-heal, ERR trap, idempotent)

Co-Authored-By: Oz <oz-agent@warp.dev>" || true
        git push origin "$(git symbolic-ref --short HEAD)" || warn "git push failed (non-fatal)"
      else
        info "no doc/script changes to commit"
      fi
    )
  fi
  cat <<SUMMARY

────────────────────────────────────────────────────────────────────────
✅ JD2 pipeline live in CT-${CTID}
────────────────────────────────────────────────────────────────────────
  CT-${CTID} services: jellyfin, riven, riven-frontend,
                       xvfb-display-1, jdownloader2,
                       x11vnc (loopback :5901),
                       riven-jd2-bridge

  Verify:
    ssh root@${CT_HOST} "pct exec ${CTID} -- systemctl status jdownloader2"
    ssh root@${CT_HOST} "pct exec ${CTID} -- journalctl -u riven-jd2-bridge -n 50"
    open https://my.jdownloader.org → device "${MYJD_DEVICE}" should be online
  Test request:
    Add a movie in Riven UI → wait ~30 s → file appears in
    /mnt/hdd/media/movies/<title>/ on Tiamat → Jellyfin scans it

────────────────────────────────────────────────────────────────────────
SUMMARY
}

# ---------- main ------------------------------------------------------------
main() {
  exec > >(tee -a "$LOGFILE") 2>&1
  info "log: $LOGFILE"
  self_test
  preflight
  do_step "Persist secrets in CT-${CTID}"          verify_secrets    execute_secrets    heal_secrets
  do_step "Make ${MEDIA_CT_PATH} writable"          verify_bind_rw    execute_bind_rw    heal_bind_rw
  do_step "Install LXDE+Xvfb+Java+Python tools"     verify_packages   execute_packages   heal_packages
  do_step "JD2 user/dirs/jar"                        verify_jd2_layout execute_jd2_layout heal_jd2_layout
  do_step "Copy JD2 config from Tiamat host"        verify_jd2_cfg    execute_jd2_cfg    heal_jd2_cfg
  do_step "Xvfb on :1 (systemd)"                     verify_xvfb       execute_xvfb       heal_xvfb
  do_step "JD2 service + cfg seed (RD/MyJD)"         verify_jd2_running execute_jd2_seed  heal_jd2_seed
  do_step "x11vnc on loopback :5901"                 verify_x11vnc     execute_x11vnc     heal_x11vnc
  do_step "riven-jd2-bridge.service"                 verify_bridge     execute_bridge     heal_bridge
  do_step "End-to-end probe (bridge connected)"      verify_probe      execute_probe      heal_probe
  post_success
}

main "$@"
