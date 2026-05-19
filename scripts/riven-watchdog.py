#!/usr/bin/env python3
"""riven-watchdog — full-chain self-healing for the post-*arr CT-300 stack.

Direct adaptation of upstream's media-pipeline-watchdog.py (homelab-media-stack)
for the bulletproof-mediastack architecture: everything runs in CT-300, the
download/import chain (Jellyseerr → *arr → qBit → import → Jellyfin) collapses
into Riven (frontend → backend → RivenVFS → Jellyfin), and there is no torrent
client.

Verifies and auto-repairs every link in the post-arr chain:
  WireGuard tunnel → PostgreSQL → Redis → Riven backend (RivenVFS at /mount)
  → Riven frontend → Jellyfin → Caddy

Designed to run as root inside CT-300 from a systemd timer every 5 minutes.
All configuration lives in /etc/riven-watchdog.json (one argument).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

WARN_COUNT = 0
FIX_COUNT = 0
FAIL_COUNT = 0


def log(msg: str) -> None:
    """Print and bump the relevant counter based on severity tag."""
    global WARN_COUNT, FIX_COUNT, FAIL_COUNT
    if msg.startswith("[WARN]"):
        WARN_COUNT += 1
    elif msg.startswith("[FIXED]"):
        FIX_COUNT += 1
    elif msg.startswith("[FAIL]"):
        FAIL_COUNT += 1
    print(msg, flush=True)


# ---------------------------------------------------------------------------
# HTTP helpers (stdlib only — keeps the watchdog dependency-free)
# ---------------------------------------------------------------------------
def http(method: str, url: str, headers: dict | None = None, data=None,
         timeout: int = 15):
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers = dict(headers or {})
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers or {},
                                 method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        ctype = resp.headers.get("Content-Type", "")
        raw = resp.read()
        if "application/json" in ctype and raw:
            return resp.status, json.loads(raw.decode())
        return resp.status, raw.decode(errors="replace")


def http_ok(url: str, headers: dict | None = None, timeout: int = 5) -> bool:
    try:
        code, _ = http("GET", url, headers=headers, timeout=timeout)
        return 200 <= code < 400
    except Exception:
        return False


# ---------------------------------------------------------------------------
# systemctl helpers
# ---------------------------------------------------------------------------
def systemctl(*args: str) -> tuple[int, str]:
    p = subprocess.run(["systemctl", *args], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def is_active(unit: str) -> bool:
    rc, _ = systemctl("is-active", "--quiet", unit)
    return rc == 0


def heal_service(unit: str, label: str | None = None) -> bool:
    """Reset-failed + restart a unit. Returns True if it ends up active."""
    label = label or unit
    log(f"[FIXED] {label}: reset-failed + restart")
    systemctl("reset-failed", unit)
    rc, out = systemctl("restart", unit)
    if rc != 0:
        log(f"[FAIL] {label}: restart failed: {out[:200]}")
        return False
    # Wait up to 30 s for the unit to settle into active.
    for _ in range(15):
        if is_active(unit):
            return True
        time.sleep(2)
    log(f"[FAIL] {label}: did not become active within 30 s")
    return False


def journal_tail(unit: str, lines: int = 20) -> str:
    p = subprocess.run(
        ["journalctl", "--no-pager", "-u", unit, "-n", str(lines)],
        capture_output=True, text=True)
    return p.stdout.strip()


# ---------------------------------------------------------------------------
# 1. WireGuard / kill-switch sanity
# ---------------------------------------------------------------------------
def check_wireguard(cfg: dict) -> None:
    wg = cfg.get("wireguard")
    if not wg or not wg.get("enabled", False):
        log("[OK] WireGuard: not configured (egress is direct)")
        return
    iface = wg.get("interface", "wg0")
    test_url = wg.get("test_url", "https://api.ipify.org")
    expected_not_ip = wg.get("home_ip", "").strip()

    # Interface up?
    rc, _ = subprocess.run(["wg", "show", iface], capture_output=True).returncode, None
    if rc != 0:
        log(f"[FAIL] WireGuard ({iface}): interface not present")
        unit = f"wg-quick@{iface}.service"
        if not heal_service(unit, label=unit):
            return

    # Egress IP via wg0 — must differ from home IP if configured.
    try:
        # `curl --interface wg0` is the canonical leak-test.
        p = subprocess.run(
            ["curl", "-fsS", "--max-time", "10", "--interface", iface, test_url],
            capture_output=True, text=True)
        if p.returncode != 0 or not p.stdout.strip():
            log(f"[FAIL] WireGuard: egress probe via {iface} failed")
            return
        exit_ip = p.stdout.strip()
        if expected_not_ip and exit_ip == expected_not_ip:
            log(f"[FAIL] WireGuard: exit IP {exit_ip} matches home IP — leak")
            return
        log(f"[OK] WireGuard: egress IP via {iface} = {exit_ip}")
    except Exception as e:
        log(f"[FAIL] WireGuard: egress probe raised {e}")


# ---------------------------------------------------------------------------
# 2. Local data services
# ---------------------------------------------------------------------------
def check_postgres(cfg: dict) -> None:
    pg = cfg.get("postgres", {})
    dsn = pg.get("dsn", "host=127.0.0.1 user=postgres password=postgres dbname=riven")
    env = dict(os.environ)
    env["PGPASSWORD"] = pg.get("password", "postgres")
    p = subprocess.run(
        ["psql", "-h", pg.get("host", "127.0.0.1"),
         "-U", pg.get("user", "postgres"),
         "-d", pg.get("database", "riven"),
         "-tAc", "SELECT 1"],
        env=env, capture_output=True, text=True, timeout=10)
    if p.returncode == 0 and p.stdout.strip() == "1":
        log("[OK] PostgreSQL: TCP auth ok, db=riven")
    else:
        log(f"[FAIL] PostgreSQL: SELECT 1 returned rc={p.returncode}: {p.stderr.strip()[:200]}")
        heal_service("postgresql.service", "PostgreSQL")


def check_redis(cfg: dict) -> None:
    p = subprocess.run(["redis-cli", "-h", "127.0.0.1", "ping"],
                       capture_output=True, text=True, timeout=5)
    if "PONG" in p.stdout:
        log("[OK] Redis: PONG")
    else:
        log(f"[FAIL] Redis: no PONG: {p.stderr.strip()[:200]}")
        heal_service("redis-server.service", "Redis")


# ---------------------------------------------------------------------------
# 3. RivenVFS mount sanity
# ---------------------------------------------------------------------------
def check_rivenvfs(cfg: dict) -> None:
    mount_path = cfg.get("riven", {}).get("mount_path", "/mount")
    # `findmnt -t fuse.RivenVFS` is the cleanest check; fall back to /proc/mounts.
    p = subprocess.run(["findmnt", "-T", mount_path, "-no", "FSTYPE,SOURCE"],
                       capture_output=True, text=True)
    fs = p.stdout.strip()
    if "fuse" in fs.lower() and "rivenvfs" in fs.lower():
        log(f"[OK] RivenVFS: mounted at {mount_path} ({fs})")
        return
    if "fuse" in fs.lower():
        log(f"[OK] RivenVFS: FUSE mount at {mount_path} ({fs})")
        return
    log(f"[FAIL] RivenVFS: {mount_path} is not a FUSE mount (got: {fs or 'no entry'})")
    # Try to remount by restarting riven (Riven mounts during startup).
    heal_service("riven.service", "Riven backend")


# ---------------------------------------------------------------------------
# 4. Riven backend + frontend HTTP probes
# ---------------------------------------------------------------------------
def check_riven_backend(cfg: dict) -> None:
    url = cfg.get("riven", {}).get("backend_url", "http://127.0.0.1:8080")
    if http_ok(url):
        log(f"[OK] Riven backend: HTTP 200 at {url}")
        return
    log(f"[FAIL] Riven backend: not responding at {url}")
    if heal_service("riven.service", "Riven backend"):
        if http_ok(url, timeout=10):
            log(f"[OK] Riven backend: recovered after restart")
        else:
            log(f"[FAIL] Riven backend: still not responding after restart")
            log("---- journal tail ----\n" + journal_tail("riven.service", 20))


def check_riven_frontend(cfg: dict) -> None:
    url = cfg.get("riven", {}).get("frontend_url", "http://127.0.0.1:3000")
    if http_ok(url):
        log(f"[OK] Riven frontend: HTTP 200 at {url}")
        return
    log(f"[FAIL] Riven frontend: not responding at {url}")
    if heal_service("riven-frontend.service", "Riven frontend"):
        if http_ok(url, timeout=10):
            log(f"[OK] Riven frontend: recovered after restart")
        else:
            log(f"[FAIL] Riven frontend: still not responding after restart")
            log("---- journal tail ----\n" + journal_tail("riven-frontend.service", 20))


# ---------------------------------------------------------------------------
# 5. Jellyfin
# ---------------------------------------------------------------------------
def check_jellyfin(cfg: dict) -> None:
    jf = cfg.get("jellyfin", {})
    url = jf.get("url", "http://127.0.0.1:8096")
    api_key = jf.get("api_key", "")
    healthy = False
    try:
        code, body = http("GET", f"{url}/health", timeout=10)
        if code == 200 and "Healthy" in str(body):
            log(f"[OK] Jellyfin: healthy at {url}")
            healthy = True
        else:
            log(f"[WARN] Jellyfin: health returned code={code}")
    except Exception as e:
        log(f"[FAIL] Jellyfin: /health failed: {e}")

    if not healthy:
        if heal_service("jellyfin.service", "Jellyfin"):
            if http_ok(f"{url}/health", timeout=15):
                log("[OK] Jellyfin: recovered after restart")
            else:
                log("[FAIL] Jellyfin: still down after restart")
                log("---- journal tail ----\n" + journal_tail("jellyfin.service", 20))
        return

    # Wizard completion check + library inventory (auth-gated)
    if not api_key:
        return
    try:
        code, info = http("GET", f"{url}/System/Info/Public", timeout=5)
        wizard = bool(info.get("StartupWizardCompleted")) if isinstance(info, dict) else False
        if not wizard:
            log("[WARN] Jellyfin: setup wizard not completed — UI/API will be partial")
    except Exception:
        pass

    try:
        code, libs = http("GET", f"{url}/Library/VirtualFolders",
                         headers={"X-Emby-Token": api_key}, timeout=10)
        if isinstance(libs, list):
            log(f"[OK] Jellyfin: {len(libs)} libraries configured")
        else:
            log("[WARN] Jellyfin: VirtualFolders endpoint returned non-list")
    except Exception as e:
        log(f"[WARN] Jellyfin: library check failed: {e}")


# ---------------------------------------------------------------------------
# 6. Caddy
# ---------------------------------------------------------------------------
def check_caddy(cfg: dict) -> None:
    url = cfg.get("caddy", {}).get("url", "http://127.0.0.1/riven/")
    # 200/3xx (redirect) both fine — we just want connectivity to Caddy.
    try:
        code, _ = http("GET", url, timeout=5)
        if 200 <= code < 400:
            log(f"[OK] Caddy: HTTP {code} at {url}")
            return
    except Exception:
        pass
    log(f"[FAIL] Caddy: not responding at {url}")
    if heal_service("caddy.service", "Caddy"):
        log("[OK] Caddy: restarted")


# ---------------------------------------------------------------------------
# 7. Real-Debrid token validity + expiry warning
# ---------------------------------------------------------------------------
def check_real_debrid(cfg: dict) -> None:
    rd = cfg.get("real_debrid", {})
    token = rd.get("api_key", "")
    if not token:
        return
    try:
        code, body = http("GET", "https://api.real-debrid.com/rest/1.0/user",
                         headers={"Authorization": f"Bearer {token}"}, timeout=15)
        if not isinstance(body, dict) or not body.get("username"):
            log(f"[FAIL] Real-Debrid: token rejected (HTTP {code})")
            return
        username = body.get("username")
        acct_type = body.get("type", "?")
        expiry = body.get("expiration", "")
        log(f"[OK] Real-Debrid: {username} ({acct_type}), expires {expiry}")
        # Warn if <30 days from expiration.
        try:
            exp = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
            days = (exp - datetime.now(timezone.utc)).days
            if days < 7:
                log(f"[WARN] Real-Debrid: subscription expires in {days} days — RENEW")
            elif days < 30:
                log(f"[WARN] Real-Debrid: subscription expires in {days} days")
        except Exception:
            pass
    except Exception as e:
        log(f"[FAIL] Real-Debrid: API error: {e}")


# ---------------------------------------------------------------------------
# 8. Disk pressure (catches /var/cache/riven runaway and pnpm/uv cache bloat)
# ---------------------------------------------------------------------------
def check_disk(cfg: dict) -> None:
    threshold = cfg.get("disk", {}).get("threshold_pct", 85)
    p = subprocess.run(["df", "-P", "/"], capture_output=True, text=True)
    lines = p.stdout.strip().splitlines()
    if len(lines) < 2:
        return
    parts = lines[-1].split()
    if len(parts) < 5:
        return
    used_pct = int(parts[4].rstrip("%"))
    if used_pct >= threshold:
        log(f"[WARN] Disk: rootfs {used_pct}% used (threshold {threshold}%)")
    else:
        log(f"[OK] Disk: rootfs {used_pct}% used")


# ---------------------------------------------------------------------------
# 9. Hooks (Discord webhook etc — kept identical to upstream watchdog)
# ---------------------------------------------------------------------------
def maybe_run_hook(hook: dict) -> None:
    try:
        method = hook.get("method", "POST").upper()
        if method == "POST":
            http("POST", hook["url"], hook.get("headers", {}), hook.get("body"))
        else:
            http("GET", hook["url"], hook.get("headers", {}))
        log(f"[OK] hook: {hook.get('name', '?')}")
    except Exception as e:
        log(f"[WARN] hook {hook.get('name', '?')}: {e}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    cfg_path = Path(sys.argv[1] if len(sys.argv) >= 2 else "/etc/riven-watchdog.json")
    if not cfg_path.is_file():
        print(f"riven-watchdog: config {cfg_path} missing", file=sys.stderr)
        sys.exit(2)
    cfg = json.loads(cfg_path.read_text())

    log(f"=== riven-watchdog @ {datetime.now(timezone.utc).isoformat()} ===")

    log("--- Phase 1: Egress ---")
    check_wireguard(cfg)

    log("--- Phase 2: Data services ---")
    check_postgres(cfg)
    check_redis(cfg)

    log("--- Phase 3: Riven (backend + RivenVFS) ---")
    check_rivenvfs(cfg)
    check_riven_backend(cfg)

    log("--- Phase 4: Riven (frontend) ---")
    check_riven_frontend(cfg)

    log("--- Phase 5: Jellyfin ---")
    check_jellyfin(cfg)

    log("--- Phase 6: Caddy ---")
    check_caddy(cfg)

    log("--- Phase 7: External integrations ---")
    check_real_debrid(cfg)

    log("--- Phase 8: Resource pressure ---")
    check_disk(cfg)

    hooks = cfg.get("hooks", [])
    if hooks:
        log("--- Phase 9: Hooks ---")
        for h in hooks:
            maybe_run_hook(h)

    log(f"=== Done: {WARN_COUNT} warnings, {FIX_COUNT} auto-fixes, {FAIL_COUNT} unrecovered ===")
    # Exit non-zero only if something is still broken after healing attempts.
    if FAIL_COUNT > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
