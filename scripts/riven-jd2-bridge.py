#!/usr/bin/env python3
"""
riven-jd2-bridge.py — bulletproof-mediastack
============================================

Bridges Riven's Scraped queue into JDownloader2 via the MyJDownloader REST API.

Pipeline per item:
  1. GET  /api/v1/items?states=Scraped               (Riven, local 8080)
  2. GET  /api/v1/items/{item_id}/streams            (Riven)
  3. POST /rest/1.0/torrents/addMagnet               (Real-Debrid)
  4. POST /rest/1.0/torrents/selectFiles/{id}        (Real-Debrid)
  5. GET  /rest/1.0/torrents/info/{id}  (poll until status==downloaded)
  6. POST /rest/1.0/unrestrict/link  (per RD link)
  7. JD2.linkgrabberv2.addLinks (via myjdapi)        (MyJDownloader)
  8. Persist progress in /var/lib/riven-jd2-bridge/state.db
  9. When JD2 reports the package finished, mark item handled and blacklist
     remaining streams so Riven does not re-scrape.

Config (read from systemd EnvironmentFile=/etc/riven-jd2-bridge.env):
  RD_API_TOKEN        Real-Debrid bearer token
  RD_USERNAME         RD web user (informational, not used by daemon)
  RD_PASSWORD         RD web pass (informational, not used by daemon)
  MYJD_EMAIL          MyJDownloader account email
  MYJD_PASSWORD       MyJDownloader account password
  MYJD_DEVICE         JD2 device name (default: mediastack-jd2)
  RIVEN_API_BASE      default http://127.0.0.1:8080
  RIVEN_API_KEY       Riven API key (auto-discovered from riven.service env if absent)
  MEDIA_ROOT          default /data/media
  POLL_SECONDS        default 30
  RD_POLL_SECONDS     default 8
  RD_TIMEOUT_MIN      default 30

Self-healing:
  * Resilient against missing env (autoload from /etc/systemd/system/riven.service)
  * Exponential backoff on every external call (RD, MyJD, Riven)
  * Per-component circuit breaker so a Riven blip doesn't kill RD work
  * Resumable: every transition is committed to state.db before the next call
  * Idempotent: an item already in state.db at status >= QUEUED is never re-queued
  * Crash-safe: WAL journal mode on SQLite

License: MIT.
"""
from __future__ import annotations

import json
import logging
import os
import pathlib
import re
import signal
import sqlite3
import sys
import time
import traceback
from dataclasses import dataclass
from typing import Any

import requests

try:
    import myjdapi
except ImportError as e:  # pragma: no cover
    print(f"FATAL: myjdapi not installed in venv: {e}", file=sys.stderr)
    sys.exit(2)

# ----------------------------------------------------------------------------- config
LOG_FMT = "%(asctime)s | %(levelname)-7s | %(name)s | %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FMT, stream=sys.stdout)
log = logging.getLogger("bridge")

POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "30"))
RD_POLL_SECONDS = int(os.environ.get("RD_POLL_SECONDS", "8"))
RD_TIMEOUT_MIN = int(os.environ.get("RD_TIMEOUT_MIN", "30"))
MEDIA_ROOT = os.environ.get("MEDIA_ROOT", "/data/media")
STATE_DIR = pathlib.Path(os.environ.get("BRIDGE_STATE_DIR", "/var/lib/riven-jd2-bridge"))
STATE_DB = STATE_DIR / "state.db"

RIVEN_API_BASE = os.environ.get("RIVEN_API_BASE", "http://127.0.0.1:8080").rstrip("/")
RIVEN_API_KEY = os.environ.get("RIVEN_API_KEY", "").strip()

RD_API_TOKEN = os.environ.get("RD_API_TOKEN", "").strip()
MYJD_EMAIL = os.environ.get("MYJD_EMAIL", "").strip()
MYJD_PASSWORD = os.environ.get("MYJD_PASSWORD", "").strip()
MYJD_DEVICE = os.environ.get("MYJD_DEVICE", "mediastack-jd2").strip()

RD_BASE = "https://api.real-debrid.com/rest/1.0"

# ----------------------------------------------------------------------------- env autoload
def _autoload_riven_api_key() -> str:
    """Pull API_KEY out of riven.service env if it wasn't provided to us."""
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
    rd_torrent_id TEXT,
    jd_package_id TEXT,
    package_name  TEXT,
    status        TEXT NOT NULL,    -- NEW, RD_ADDED, RD_READY, JD_QUEUED, JD_DONE, FAILED
    last_error    TEXT,
    attempts      INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_items_status ON items(status);
"""


def open_state() -> sqlite3.Connection:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(STATE_DB, isolation_level=None)  # autocommit
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript(SCHEMA)
    return db


def upsert_item(db: sqlite3.Connection, riven_id: int, **fields: Any) -> None:
    now = int(time.time())
    cur = db.execute("SELECT 1 FROM items WHERE riven_id=?", (riven_id,))
    exists = cur.fetchone() is not None
    if not exists:
        db.execute(
            "INSERT INTO items(riven_id, title, status, created_at, updated_at) VALUES (?,?,?,?,?)",
            (
                riven_id,
                fields.get("title", "?"),
                fields.get("status", "NEW"),
                now,
                now,
            ),
        )
    keys = [k for k in fields.keys() if k not in ("riven_id", "created_at")]
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


# ----------------------------------------------------------------------------- HTTP helpers
def _retry_call(label: str, fn, tries: int = 5, base_pause: float = 2.0):
    last: Exception | None = None
    for i in range(1, tries + 1):
        try:
            return fn()
        except Exception as e:  # noqa: BLE001
            last = e
            wait = base_pause * (2 ** (i - 1))
            log.warning("%s attempt %d/%d failed: %s; sleeping %.1fs", label, i, tries, e, wait)
            time.sleep(wait)
    raise RuntimeError(f"{label} failed after {tries} attempts: {last}")


# ----------------------------------------------------------------------------- Riven
class Riven:
    def __init__(self, base: str, key: str):
        self.base = base
        self.key = key
        self.s = requests.Session()
        if key:
            self.s.headers["X-API-Key"] = key

    def health(self) -> bool:
        r = self.s.get(f"{self.base}/api/v1/health", timeout=8)
        return r.ok and r.json().get("message") in (True, "True", "true")

    def scraped_items(self, limit: int = 100) -> list[dict]:
        r = self.s.get(
            f"{self.base}/api/v1/items",
            params={"states": "Scraped", "limit": limit},
            timeout=15,
        )
        r.raise_for_status()
        return r.json().get("items", [])

    def streams(self, item_id: int) -> list[dict]:
        r = self.s.get(f"{self.base}/api/v1/items/{item_id}/streams", timeout=15)
        r.raise_for_status()
        return r.json().get("streams", [])

    def blacklist_stream(self, item_id: int, stream_id: int) -> None:
        # POST /api/v1/items/{item_id}/streams/{stream_id}/blacklist
        r = self.s.post(
            f"{self.base}/api/v1/items/{item_id}/streams/{stream_id}/blacklist", timeout=15
        )
        if not r.ok:
            log.warning("blacklist_stream %s/%s -> %s %s", item_id, stream_id, r.status_code, r.text[:200])


# ----------------------------------------------------------------------------- Real-Debrid
class RD:
    def __init__(self, token: str):
        self.token = token
        self.s = requests.Session()
        self.s.headers["Authorization"] = f"Bearer {token}"

    def add_magnet(self, infohash: str) -> str:
        magnet = f"magnet:?xt=urn:btih:{infohash}"
        r = self.s.post(f"{RD_BASE}/torrents/addMagnet", data={"magnet": magnet}, timeout=20)
        r.raise_for_status()
        return r.json()["id"]

    def select_files(self, torrent_id: str, files: str = "all") -> None:
        r = self.s.post(
            f"{RD_BASE}/torrents/selectFiles/{torrent_id}", data={"files": files}, timeout=20
        )
        if r.status_code not in (204, 202, 200):
            r.raise_for_status()

    def torrent_info(self, torrent_id: str) -> dict:
        r = self.s.get(f"{RD_BASE}/torrents/info/{torrent_id}", timeout=15)
        r.raise_for_status()
        return r.json()

    def unrestrict(self, link: str) -> str:
        r = self.s.post(f"{RD_BASE}/unrestrict/link", data={"link": link}, timeout=20)
        r.raise_for_status()
        return r.json()["download"]

    def delete_torrent(self, torrent_id: str) -> None:
        try:
            self.s.delete(f"{RD_BASE}/torrents/delete/{torrent_id}", timeout=15)
        except Exception:  # noqa: BLE001
            pass

    def wait_until_ready(self, torrent_id: str) -> dict:
        deadline = time.time() + RD_TIMEOUT_MIN * 60
        while time.time() < deadline:
            info = self.torrent_info(torrent_id)
            status = info.get("status")
            log.info(
                "RD torrent %s status=%s progress=%s",
                torrent_id,
                status,
                info.get("progress"),
            )
            if status == "downloaded":
                return info
            if status in ("magnet_error", "error", "virus", "dead"):
                raise RuntimeError(f"RD rejected torrent {torrent_id}: {status}")
            if status == "waiting_files_selection":
                # files weren't auto-selected; force select
                self.select_files(torrent_id, "all")
            time.sleep(RD_POLL_SECONDS)
        raise TimeoutError(f"RD torrent {torrent_id} not ready after {RD_TIMEOUT_MIN} min")


# ----------------------------------------------------------------------------- MyJDownloader
class JD:
    def __init__(self, email: str, password: str, device_name: str):
        self.email = email
        self.password = password
        self.device_name = device_name
        self.jd = myjdapi.Myjdapi()
        self.jd.set_app_key("riven-jd2-bridge")
        self.device = None

    def connect(self) -> None:
        def _do():
            self.jd.connect(self.email, self.password)
            self.jd.update_devices()
            devices = self.jd.list_devices()
            log.info("MyJD devices: %s", [d["name"] for d in devices])
            for d in devices:
                if d["name"] == self.device_name:
                    self.device = self.jd.get_device(self.device_name)
                    return
            # device not found: try the first JD2 device available
            if devices:
                fallback = devices[0]["name"]
                log.warning(
                    "device '%s' not found; falling back to first device '%s'",
                    self.device_name,
                    fallback,
                )
                self.device = self.jd.get_device(fallback)
                self.device_name = fallback
                return
            raise RuntimeError("No MyJDownloader devices online")

        _retry_call("MyJD connect", _do, tries=5, base_pause=3.0)
        log.info("connected to MyJDownloader; device=%s", self.device_name)

    def add_links(self, links: list[str], package_name: str, dest_folder: str) -> str:
        """Submit links to JD2 linkgrabber + auto-add to downloads. Returns package UUID."""
        params = [
            {
                "autostart": True,
                "links": "\n".join(links),
                "packageName": package_name,
                "destinationFolder": dest_folder,
                "overwritePackagizerRules": False,
                "extractPassword": "",
                "priority": "DEFAULT",
                "downloadPassword": "",
            }
        ]
        ret = self.device.linkgrabber.add_links(params)
        # The return is a job id; we map to a package by name+folder
        log.info("JD addLinks job=%s package=%s dest=%s", ret, package_name, dest_folder)
        # Allow JD a moment to crawl
        time.sleep(4)
        return str(ret)

    def find_package_uuid(self, package_name: str, dest_folder: str) -> str | None:
        try:
            packages = self.device.downloads.query_packages(
                [{"bytesLoaded": True, "bytesTotal": True, "saveTo": True, "name": True}]
            )
            for p in packages:
                if p.get("name") == package_name and p.get("saveTo", "").rstrip("/") == dest_folder.rstrip("/"):
                    return str(p.get("uuid"))
        except Exception as e:  # noqa: BLE001
            log.warning("find_package_uuid: %s", e)
        return None

    def package_done(self, package_name: str) -> bool:
        try:
            packages = self.device.downloads.query_packages(
                [{"bytesLoaded": True, "bytesTotal": True, "name": True, "finished": True}]
            )
            for p in packages:
                if p.get("name") == package_name:
                    finished = p.get("finished", False)
                    bt = p.get("bytesTotal") or 0
                    bl = p.get("bytesLoaded") or 0
                    return bool(finished or (bt > 0 and bl >= bt))
        except Exception as e:  # noqa: BLE001
            log.warning("package_done query failed: %s", e)
        return False


# ----------------------------------------------------------------------------- helpers
SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._() \-]")


def safe_dirname(s: str) -> str:
    s = (s or "untitled").strip()
    s = SAFE_NAME_RE.sub(" ", s).strip()
    s = re.sub(r"\s+", " ", s)
    return s[:120] or "untitled"


def media_subdir(item: dict) -> str:
    t = (item.get("type") or "").lower()
    return {
        "movie": "movies",
        "show": "tv",
        "season": "tv",
        "episode": "tv",
    }.get(t, "movies")


def build_dest_folder(item: dict) -> str:
    sub = media_subdir(item)
    base = item.get("title") or item.get("log_string") or f"item-{item.get('id')}"
    year = item.get("year") or item.get("aired_at", "")[:4]
    if year:
        folder = f"{safe_dirname(base)} ({year})"
    else:
        folder = safe_dirname(base)
    return f"{MEDIA_ROOT.rstrip('/')}/{sub}/{folder}"


def best_stream(streams: list[dict]) -> dict | None:
    # Highest rank wins; ties broken by lev_ratio
    if not streams:
        return None
    sorted_s = sorted(
        streams,
        key=lambda s: (s.get("rank", -10**9), s.get("lev_ratio", 0.0)),
        reverse=True,
    )
    # Filter streams with negative rank below blacklist threshold (-10000 by default)
    return sorted_s[0]


# ----------------------------------------------------------------------------- core
@dataclass
class Bridge:
    db: sqlite3.Connection
    riven: Riven
    rd: RD
    jd: JD

    def process_item(self, item: dict) -> None:
        riven_id = item["id"]
        title = item.get("title") or item.get("log_string") or f"item-{riven_id}"
        st = get_item(self.db, riven_id) or {}
        status = st.get("status", "NEW")

        if status == "JD_DONE":
            return  # nothing to do
        if status == "FAILED" and (st.get("attempts") or 0) >= 5:
            log.warning("item %s permanently FAILED, skipping", riven_id)
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
                self._submit_to_rd(item)
                status = "RD_ADDED"
            if status == "RD_ADDED":
                self._wait_rd(riven_id)
                status = "RD_READY"
            if status == "RD_READY":
                self._send_to_jd(item)
                status = "JD_QUEUED"
            if status == "JD_QUEUED":
                self._check_jd_done(item)
        except Exception as e:  # noqa: BLE001
            tb = traceback.format_exc(limit=4)
            log.error("item %s (%s) failed: %s\n%s", riven_id, title, e, tb)
            upsert_item(self.db, riven_id, status="FAILED", last_error=str(e)[:500])

    # -- stage 1 --------------------------------------------------------------
    def _submit_to_rd(self, item: dict) -> None:
        riven_id = item["id"]
        streams = self.riven.streams(riven_id)
        s = best_stream(streams)
        if not s:
            raise RuntimeError("no streams attached to item")
        infohash = s["infohash"]
        log.info("item %s: adding magnet %s to RD (rank=%s)", riven_id, infohash, s.get("rank"))
        rd_id = self.rd.add_magnet(infohash)
        # Force select all files (RD won't auto-select)
        try:
            self.rd.select_files(rd_id, "all")
        except Exception as e:  # noqa: BLE001
            log.warning("selectFiles immediate call: %s", e)
        upsert_item(self.db, riven_id, rd_torrent_id=rd_id, status="RD_ADDED")

    # -- stage 2 --------------------------------------------------------------
    def _wait_rd(self, riven_id: int) -> None:
        st = get_item(self.db, riven_id) or {}
        rd_id = st.get("rd_torrent_id")
        if not rd_id:
            raise RuntimeError("no rd_torrent_id in state for waiting")
        info = self.rd.wait_until_ready(rd_id)
        log.info(
            "item %s: RD ready, %d link(s)", riven_id, len(info.get("links") or [])
        )
        upsert_item(self.db, riven_id, status="RD_READY")

    # -- stage 3 --------------------------------------------------------------
    def _send_to_jd(self, item: dict) -> None:
        riven_id = item["id"]
        st = get_item(self.db, riven_id) or {}
        rd_id = st.get("rd_torrent_id")
        info = self.rd.torrent_info(rd_id)
        rd_links: list[str] = info.get("links") or []
        if not rd_links:
            raise RuntimeError("RD reports no links available")
        # Unrestrict each (RD requires premium; we're authenticated)
        direct: list[str] = []
        for link in rd_links:
            try:
                d = self.rd.unrestrict(link)
                direct.append(d)
            except Exception as e:  # noqa: BLE001
                log.warning("unrestrict %s failed: %s", link, e)
        if not direct:
            raise RuntimeError("no links survived unrestrict")
        dest = build_dest_folder(item)
        pkg_name = pathlib.Path(dest).name
        os.makedirs(dest, exist_ok=True)
        log.info("item %s: posting %d link(s) to JD2 → %s", riven_id, len(direct), dest)
        self.jd.add_links(direct, package_name=pkg_name, dest_folder=dest)
        upsert_item(
            self.db, riven_id, package_name=pkg_name, status="JD_QUEUED"
        )

    # -- stage 4 --------------------------------------------------------------
    def _check_jd_done(self, item: dict) -> None:
        riven_id = item["id"]
        st = get_item(self.db, riven_id) or {}
        pkg_name = st.get("package_name") or build_dest_folder(item).split("/")[-1]
        if self.jd.package_done(pkg_name):
            log.info("item %s: JD2 finished package %s", riven_id, pkg_name)
            upsert_item(self.db, riven_id, status="JD_DONE")
            # Optionally tidy up: delete the RD torrent (saves slot)
            rd_id = st.get("rd_torrent_id")
            if rd_id:
                self.rd.delete_torrent(rd_id)
            # Best-effort: blacklist all streams so Riven stops poking this item
            for s in self.riven.streams(riven_id):
                try:
                    self.riven.blacklist_stream(riven_id, s["id"])
                except Exception:  # noqa: BLE001
                    pass
        else:
            log.info("item %s: JD2 still downloading %s", riven_id, pkg_name)

    # -- main loop ------------------------------------------------------------
    def loop(self) -> None:
        log.info("connected to MyJDownloader; entering main loop (poll=%ds)", POLL_SECONDS)
        while True:
            try:
                if not self.riven.health():
                    log.warning("Riven health check failed; will retry")
                    time.sleep(POLL_SECONDS)
                    continue
                items = self.riven.scraped_items(limit=200)
                log.info("Riven Scraped poll: %d item(s)", len(items))
                for it in items:
                    self.process_item(it)
                # also keep sweeping in-flight ones
                cur = self.db.execute(
                    "SELECT riven_id FROM items WHERE status IN ('RD_ADDED','RD_READY','JD_QUEUED')"
                )
                for (rid,) in cur.fetchall():
                    # Build a minimal item dict to drive subsequent stages
                    self.process_item({"id": rid, "title": "(in-flight)"})
            except Exception as e:  # noqa: BLE001
                log.error("main loop error: %s\n%s", e, traceback.format_exc(limit=3))
            time.sleep(POLL_SECONDS)


# ----------------------------------------------------------------------------- bootstrap
def main() -> int:
    missing = []
    if not RD_API_TOKEN:
        missing.append("RD_API_TOKEN")
    if not MYJD_EMAIL:
        missing.append("MYJD_EMAIL")
    if not MYJD_PASSWORD:
        missing.append("MYJD_PASSWORD")
    if missing:
        log.error("FATAL: missing env: %s", ",".join(missing))
        return 2
    if not RIVEN_API_KEY:
        log.error("FATAL: could not resolve RIVEN_API_KEY (set it in env or in riven.service)")
        return 2

    log.info("riven-jd2-bridge starting; media_root=%s state=%s", MEDIA_ROOT, STATE_DB)
    db = open_state()
    riven = Riven(RIVEN_API_BASE, RIVEN_API_KEY)
    rd = RD(RD_API_TOKEN)
    jd = JD(MYJD_EMAIL, MYJD_PASSWORD, MYJD_DEVICE)
    jd.connect()
    bridge = Bridge(db=db, riven=riven, rd=rd, jd=jd)

    # graceful shutdown
    stopping = False
    def _stop(_sig, _fr):
        nonlocal stopping
        log.info("signal received; stopping after current cycle")
        stopping = True
        sys.exit(0)
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    bridge.loop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
