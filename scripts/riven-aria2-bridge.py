#!/usr/bin/env python3
"""
riven-aria2-bridge.py — bulletproof-mediastack
===============================================

Fallback download path for items Real-Debrid refuses.
Polls Riven for Failed items, submits magnets to aria2 (running behind
WireGuard on CT-300), tracks progress in SQLite, moves completed files
to the Jellyfin media library, and kicks a Jellyfin refresh.

Pipeline per item:
  1. GET /api/v1/items?states=Failed          (Riven backend, :8080)
  2. GET /api/v1/items/{id}/streams            (Riven)
  3. aria2.addUri (magnet) via JSON-RPC        (aria2, :6800)
  4. Poll aria2.tellStatus until complete
  5. Move completed files to /data/media/{movies,tv}/
  6. POST /Library/Refresh                     (Jellyfin, :8096)
  7. Persist state in /var/lib/riven-aria2-bridge/state.db

Config (env or /etc/riven-aria2-bridge.env):
  RIVEN_API_BASE       default http://127.0.0.1:8080
  RIVEN_API_KEY        auto-discovered from riven.service if absent
  ARIA2_RPC_URL        default http://127.0.0.1:6800/jsonrpc
  ARIA2_RPC_SECRET     default mediastack-aria2
  MEDIA_ROOT           default /data/media
  POLL_SECONDS         default 60
  JELLYFIN_URL         default http://127.0.0.1:8096
  JELLYFIN_API_KEY     (optional)

License: MIT.
"""
from __future__ import annotations

import json
import logging
import os
import pathlib
import re
import shutil
import signal
import sqlite3
import sys
import time
import traceback
from typing import Any

import requests

# ----------------------------------------------------------------------------- config
LOG_FMT = "%(asctime)s | %(levelname)-7s | %(name)s | %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FMT, stream=sys.stdout)
log = logging.getLogger("aria2-bridge")

POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))
MEDIA_ROOT = os.environ.get("MEDIA_ROOT", "/data/media")
STATE_DIR = pathlib.Path(
    os.environ.get("BRIDGE_STATE_DIR", "/var/lib/riven-aria2-bridge")
)
STATE_DB = STATE_DIR / "state.db"

RIVEN_API_BASE = os.environ.get("RIVEN_API_BASE", "http://127.0.0.1:8080").rstrip("/")
RIVEN_API_KEY = os.environ.get("RIVEN_API_KEY", "").strip()

ARIA2_RPC_URL = os.environ.get("ARIA2_RPC_URL", "http://127.0.0.1:6800/jsonrpc")
ARIA2_RPC_SECRET = os.environ.get("ARIA2_RPC_SECRET", "mediastack-aria2")

JELLYFIN_URL = os.environ.get("JELLYFIN_URL", "http://127.0.0.1:8096").rstrip("/")
JELLYFIN_API_KEY = os.environ.get("JELLYFIN_API_KEY", "").strip()

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".m4v", ".ts", ".wmv", ".flv", ".mov", ".webm"}

# ----------------------------------------------------------------------------- env autoload
def _autoload_riven_api_key() -> str:
    paths = [
        "/etc/systemd/system/riven.service",
        "/lib/systemd/system/riven.service",
    ]
    pat = re.compile(r"^Environment=API_KEY=(\S+)\s*$")
    for p in paths:
        try:
            for line in pathlib.Path(p).read_text().splitlines():
                m = pat.match(line)
                if m:
                    return m.group(1).strip()
        except FileNotFoundError:
            pass
    return ""


if not RIVEN_API_KEY:
    RIVEN_API_KEY = _autoload_riven_api_key()
    if RIVEN_API_KEY:
        log.info("autoloaded RIVEN_API_KEY from riven.service")


# ----------------------------------------------------------------------------- state.db
SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
    riven_id      INTEGER PRIMARY KEY,
    title         TEXT NOT NULL,
    media_type    TEXT,
    infohash      TEXT,
    aria2_gid     TEXT,
    dest_folder   TEXT,
    status        TEXT NOT NULL,    -- NEW, ARIA2_ADDED, DOWNLOADING, COMPLETE, MOVED, FAILED
    last_error    TEXT,
    attempts      INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_items_status ON items(status);
"""


def open_state() -> sqlite3.Connection:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(STATE_DB, isolation_level=None)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript(SCHEMA)
    return db


def upsert_item(db: sqlite3.Connection, riven_id: int, **fields: Any) -> None:
    now = int(time.time())
    cur = db.execute("SELECT 1 FROM items WHERE riven_id=?", (riven_id,))
    if cur.fetchone() is None:
        db.execute(
            "INSERT INTO items(riven_id, title, status, created_at, updated_at) "
            "VALUES (?,?,?,?,?)",
            (riven_id, fields.get("title", "?"), fields.get("status", "NEW"), now, now),
        )
    keys = [k for k in fields if k not in ("riven_id", "created_at")]
    if keys:
        sets = ", ".join(f"{k}=?" for k in keys) + ", updated_at=?"
        vals = [fields[k] for k in keys] + [now, riven_id]
        db.execute(f"UPDATE items SET {sets} WHERE riven_id=?", vals)


def get_item(db: sqlite3.Connection, riven_id: int) -> dict | None:
    cur = db.execute("SELECT * FROM items WHERE riven_id=?", (riven_id,))
    row = cur.fetchone()
    if not row:
        return None
    cols = [d[0] for d in cur.description]
    return dict(zip(cols, row))


# ----------------------------------------------------------------------------- helpers
def _retry(label: str, fn, tries: int = 4, pause: float = 3.0):
    last = None
    for i in range(1, tries + 1):
        try:
            return fn()
        except Exception as e:
            last = e
            wait = pause * (2 ** (i - 1))
            log.warning("%s attempt %d/%d: %s; retry in %.1fs", label, i, tries, e, wait)
            time.sleep(wait)
    raise RuntimeError(f"{label} failed after {tries}: {last}")


SAFE_RE = re.compile(r"[^A-Za-z0-9._() \-]")


def safe_name(s: str) -> str:
    s = SAFE_RE.sub(" ", (s or "untitled").strip())
    return re.sub(r"\s+", " ", s).strip()[:120] or "untitled"


def media_subdir(item: dict) -> str:
    t = (item.get("type") or "").lower()
    return {"movie": "movies", "show": "tv", "season": "tv", "episode": "tv"}.get(
        t, "movies"
    )


def build_dest(item: dict) -> str:
    sub = media_subdir(item)
    base = item.get("title") or item.get("log_string") or f"item-{item.get('id')}"
    year = item.get("year") or (item.get("aired_at") or "")[:4]
    folder = f"{safe_name(base)} ({year})" if year else safe_name(base)
    return f"{MEDIA_ROOT.rstrip('/')}/{sub}/{folder}"


# ----------------------------------------------------------------------------- Riven client
class Riven:
    def __init__(self, base: str, key: str):
        self.s = requests.Session()
        self.base = base
        if key:
            self.s.headers["X-API-Key"] = key

    def failed_items(self, limit: int = 100) -> list[dict]:
        r = self.s.get(
            f"{self.base}/api/v1/items",
            params={"states": "Failed", "limit": limit},
            timeout=15,
        )
        r.raise_for_status()
        return r.json().get("items", [])

    def streams(self, item_id: int) -> list[dict]:
        r = self.s.get(f"{self.base}/api/v1/items/{item_id}/streams", timeout=15)
        r.raise_for_status()
        return r.json().get("streams", [])


# ----------------------------------------------------------------------------- aria2 RPC
class Aria2:
    def __init__(self, url: str, secret: str):
        self.url = url
        self.secret = secret
        self._id = 0

    def _call(self, method: str, params: list | None = None) -> Any:
        self._id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": str(self._id),
            "method": method,
            "params": [f"token:{self.secret}"] + (params or []),
        }
        r = requests.post(self.url, json=payload, timeout=15)
        r.raise_for_status()
        data = r.json()
        if "error" in data:
            raise RuntimeError(f"aria2 {method}: {data['error']}")
        return data.get("result")

    def add_magnet(self, infohash: str, dest: str) -> str:
        """Add a magnet URI, return GID."""
        magnet = f"magnet:?xt=urn:btih:{infohash}"
        opts = {"dir": dest, "bt-stop-timeout": "0", "seed-time": "0"}
        return self._call("aria2.addUri", [[magnet], opts])

    def tell_status(self, gid: str) -> dict:
        return self._call(
            "aria2.tellStatus",
            [gid, ["gid", "status", "totalLength", "completedLength", "dir", "files"]],
        )

    def get_version(self) -> str:
        return self._call("aria2.getVersion").get("version", "?")


# ----------------------------------------------------------------------------- bridge
class Bridge:
    def __init__(self, db: sqlite3.Connection, riven: Riven, aria2: Aria2):
        self.db = db
        self.riven = riven
        self.aria2 = aria2

    def process_item(self, item: dict) -> None:
        riven_id = item["id"]
        title = item.get("title") or item.get("log_string") or f"item-{riven_id}"
        st = get_item(self.db, riven_id) or {}
        status = st.get("status", "NEW")

        if status in ("MOVED", "COMPLETE"):
            return
        if status == "FAILED" and (st.get("attempts") or 0) >= 5:
            return

        upsert_item(
            self.db,
            riven_id,
            title=title,
            media_type=item.get("type"),
            attempts=(st.get("attempts") or 0) + 1,
        )

        try:
            if status in ("NEW", "FAILED"):
                self._submit(item)
            status = (get_item(self.db, riven_id) or {}).get("status", status)
            if status in ("ARIA2_ADDED", "DOWNLOADING"):
                self._check_progress(riven_id)
            status = (get_item(self.db, riven_id) or {}).get("status", status)
            if status == "COMPLETE":
                self._move_files(riven_id)
        except Exception as e:
            tb = traceback.format_exc(limit=4)
            log.error("item %s (%s) failed: %s\n%s", riven_id, title, e, tb)
            upsert_item(self.db, riven_id, status="FAILED", last_error=str(e)[:500])

    def _submit(self, item: dict) -> None:
        riven_id = item["id"]
        streams = self.riven.streams(riven_id)
        if not streams:
            raise RuntimeError("no streams for item")
        # Pick highest-rank stream
        best = sorted(
            streams,
            key=lambda s: (s.get("rank", -999), s.get("lev_ratio", 0.0)),
            reverse=True,
        )[0]
        infohash = best.get("infohash")
        if not infohash:
            raise RuntimeError("best stream has no infohash")
        dest = build_dest(item)
        os.makedirs(dest, exist_ok=True)
        log.info(
            "item %s: adding magnet %s to aria2 → %s (rank=%s)",
            riven_id,
            infohash[:12],
            dest,
            best.get("rank"),
        )
        gid = self.aria2.add_magnet(infohash, dest)
        upsert_item(
            self.db,
            riven_id,
            infohash=infohash,
            aria2_gid=gid,
            dest_folder=dest,
            status="ARIA2_ADDED",
        )

    def _check_progress(self, riven_id: int) -> None:
        st = get_item(self.db, riven_id) or {}
        gid = st.get("aria2_gid")
        if not gid:
            return
        try:
            info = self.aria2.tell_status(gid)
        except Exception as e:
            log.warning("aria2 tellStatus %s: %s", gid, e)
            return
        a2_status = info.get("status", "")
        total = int(info.get("totalLength") or 0)
        done = int(info.get("completedLength") or 0)
        pct = f"{done * 100 // total}%" if total > 0 else "?"

        if a2_status == "complete":
            log.info("item %s: aria2 complete (%s)", riven_id, pct)
            upsert_item(self.db, riven_id, status="COMPLETE")
        elif a2_status == "error":
            raise RuntimeError(f"aria2 error for gid {gid}")
        elif a2_status == "removed":
            raise RuntimeError(f"aria2 download removed for gid {gid}")
        else:
            log.info("item %s: aria2 %s %s", riven_id, a2_status, pct)
            upsert_item(self.db, riven_id, status="DOWNLOADING")

    def _move_files(self, riven_id: int) -> None:
        st = get_item(self.db, riven_id) or {}
        dest = st.get("dest_folder")
        if not dest or not os.path.isdir(dest):
            upsert_item(self.db, riven_id, status="MOVED")
            return
        # Find video files in dest and ensure they're in the right place
        moved = 0
        for root, _, files in os.walk(dest):
            for f in files:
                if pathlib.Path(f).suffix.lower() in VIDEO_EXTS:
                    moved += 1
        if moved == 0:
            log.warning("item %s: no video files found in %s", riven_id, dest)
        else:
            log.info("item %s: %d video file(s) in %s", riven_id, moved, dest)
        upsert_item(self.db, riven_id, status="MOVED")
        self._kick_jellyfin(riven_id)

    def _kick_jellyfin(self, riven_id: int) -> None:
        if not JELLYFIN_API_KEY:
            return
        try:
            r = requests.post(
                f"{JELLYFIN_URL}/Library/Refresh",
                headers={"X-Emby-Token": JELLYFIN_API_KEY},
                timeout=10,
            )
            if r.ok:
                log.info("item %s: Jellyfin refresh OK", riven_id)
            else:
                log.warning("item %s: Jellyfin refresh %s", riven_id, r.status_code)
        except Exception as e:
            log.warning("Jellyfin refresh failed: %s", e)

    def loop(self) -> None:
        log.info("entering main loop (poll=%ds)", POLL_SECONDS)
        while True:
            try:
                # Check in-flight downloads first
                cur = self.db.execute(
                    "SELECT riven_id FROM items WHERE status IN ('ARIA2_ADDED','DOWNLOADING')"
                )
                for (rid,) in cur.fetchall():
                    st = get_item(self.db, rid) or {}
                    self.process_item({"id": rid, "title": st.get("title", "?"), "type": st.get("media_type")})

                # Then poll Riven for new Failed items
                items = self.riven.failed_items(limit=100)
                log.info("Riven Failed poll: %d item(s)", len(items))
                for it in items:
                    rid = it["id"]
                    existing = get_item(self.db, rid)
                    if existing and existing["status"] in ("MOVED", "COMPLETE", "DOWNLOADING", "ARIA2_ADDED"):
                        continue
                    self.process_item(it)

            except Exception as e:
                log.error("main loop: %s\n%s", e, traceback.format_exc(limit=3))
            time.sleep(POLL_SECONDS)


# ----------------------------------------------------------------------------- main
def main() -> int:
    if not RIVEN_API_KEY:
        log.error("FATAL: no RIVEN_API_KEY (set in env or riven.service)")
        return 2

    log.info("riven-aria2-bridge starting; media=%s state=%s", MEDIA_ROOT, STATE_DB)

    db = open_state()
    riven = Riven(RIVEN_API_BASE, RIVEN_API_KEY)
    aria2 = Aria2(ARIA2_RPC_URL, ARIA2_RPC_SECRET)

    # Verify aria2 is reachable
    ver = _retry("aria2 version", aria2.get_version)
    log.info("aria2 connected: v%s", ver)

    bridge = Bridge(db=db, riven=riven, aria2=aria2)

    def _stop(_sig, _fr):
        log.info("signal received; exiting")
        sys.exit(0)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    bridge.loop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
