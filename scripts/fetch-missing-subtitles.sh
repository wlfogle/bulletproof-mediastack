#!/usr/bin/env bash
# fetch-missing-subtitles.sh — walk /mnt/hdd/media and download missing
# subtitle .srt files using `subliminal` (the same engine Bazarr uses).
#
# Run on the Proxmox host (tiamat) where /mnt/hdd/media is a local fs.
# Idempotent: subliminal skips files that already have a sibling .srt.
#
# Configuration (env vars, all optional):
#   LANGS                  space-separated ISO 639-1 codes; default "en"
#   ROOTS                  space-separated dirs; default tv/movies/anime
#   PROVIDERS              space-separated subliminal providers (see below)
#   OPENSUBTITLES_USER     opensubtitles.com username (raises rate limit)
#   OPENSUBTITLES_PASS     opensubtitles.com password
#   MIN_SCORE              subliminal min match score; default 0 (any match)
#   WORKERS                parallel workers per directory; default 4
#
# Recommended providers (no creds needed):
#   podnapisi, tvsubtitles, gestdown, opensubtitles
# With creds (much higher rate limit, better matches):
#   opensubtitlescom, opensubtitlescomvip, addic7ed
#
# Subliminal docs: https://subliminal.readthedocs.io

set -uo pipefail

LANGS="${LANGS:-en}"
ROOTS="${ROOTS:-/mnt/hdd/media/tv /mnt/hdd/media/movies /mnt/hdd/media/anime}"
PROVIDERS="${PROVIDERS:-podnapisi tvsubtitles gestdown opensubtitles}"
MIN_SCORE="${MIN_SCORE:-0}"
WORKERS="${WORKERS:-4}"
VENV="${VENV:-/opt/subliminal-venv}"
CACHE="${CACHE:-/var/cache/subliminal}"

C_INFO=$'\e[1;36m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_RST=$'\e[0m'
log()  { printf '%s[fetch-subs]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s[fetch-subs]%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '%s[fetch-subs]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { warn "must run as root"; exit 1; }

############################################################################
# 1. Install subliminal in a venv (one-time, idempotent)
############################################################################
ensure_subliminal() {
  log "ensuring subliminal venv at $VENV"
  local APT=apt-get
  command -v nala >/dev/null 2>&1 && APT=nala
  if ! dpkg -s python3-venv >/dev/null 2>&1; then
    $APT update -y >/dev/null 2>&1 || true
    $APT install -y python3-venv python3-pip ffmpeg >/dev/null
  fi
  if [ ! -x "$VENV/bin/subliminal" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip wheel
    # subliminal[tv] pulls in stevedore + babelfish + guessit
    "$VENV/bin/pip" install -q --upgrade 'subliminal[tv]'
  fi
  ok "subliminal $("$VENV/bin/subliminal" --version 2>&1 | head -1)"
  install -d -m 0755 "$CACHE"
}

############################################################################
# 2. Build provider args (with optional creds)
############################################################################
build_provider_args() {
  PROV_ARGS=()
  for p in $PROVIDERS; do PROV_ARGS+=( -p "$p" ); done
  CRED_ARGS=()
  if [ -n "${OPENSUBTITLES_USER:-}" ] && [ -n "${OPENSUBTITLES_PASS:-}" ]; then
    CRED_ARGS+=( --opensubtitles "$OPENSUBTITLES_USER" "$OPENSUBTITLES_PASS" )
    if [[ "$PROVIDERS" == *opensubtitlescom* ]]; then
      CRED_ARGS+=( --opensubtitlescom "$OPENSUBTITLES_USER" "$OPENSUBTITLES_PASS" )
    fi
  fi
  if [ -n "${ADDIC7ED_USER:-}" ] && [ -n "${ADDIC7ED_PASS:-}" ]; then
    CRED_ARGS+=( --addic7ed "$ADDIC7ED_USER" "$ADDIC7ED_PASS" )
  fi
}

############################################################################
# 3. Walk each root and let subliminal do its thing
############################################################################
run_one_root() {
  local root="$1"
  if [ ! -d "$root" ]; then
    warn "skip $root (not a directory)"
    return 0
  fi
  local total
  total=$(find "$root" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.m4v' -o -iname '*.ts' \) 2>/dev/null | wc -l)
  log "=== $root :: $total video files ==="
  if [ "$total" -eq 0 ]; then return 0; fi

  local LANG_ARGS=()
  for l in $LANGS; do LANG_ARGS+=( -l "$l" ); done

  # subliminal exits 0 even when nothing is downloaded; failures emit logs.
  "$VENV/bin/subliminal" \
      --cache-dir "$CACHE" \
      "${CRED_ARGS[@]}" \
      download \
      "${LANG_ARGS[@]}" \
      "${PROV_ARGS[@]}" \
      -w "$WORKERS" \
      -m "$MIN_SCORE" \
      "$root"
}

############################################################################
# main
############################################################################
ensure_subliminal
build_provider_args

started=$(date -Iseconds)
log "starting at $started"
log "providers: $PROVIDERS"
log "languages: $LANGS"
log "workers:   $WORKERS"
log "roots:     $ROOTS"

for r in $ROOTS; do
  run_one_root "$r" || warn "root $r returned non-zero"
done

ended=$(date -Iseconds)
ok "done   $started -> $ended"

############################################################################
# Post-run audit
############################################################################
echo
log "post-run audit (still missing English subtitle siblings):"
total_missing=0
for r in $ROOTS; do
  [ -d "$r" ] || continue
  miss=$(find "$r" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.m4v' -o -iname '*.ts' \) \
         -exec sh -c 'b="${1%.*}"; [ ! -f "$b.en.srt" ] && [ ! -f "$b.srt" ] && echo "$1"' _ {} \; \
         2>/dev/null | wc -l)
  printf '  %s : %d files still without .srt\n' "$r" "$miss"
  total_missing=$((total_missing + miss))
done
ok "total still missing: $total_missing"
