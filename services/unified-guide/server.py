#!/usr/bin/env python3
"""
unified-guide — single grid covering OTA, IPTV, YouTube TV, SVOD (TMDB
JustWatch), and the local Jellyfin library. Click any cell -> the right
app/site launches and plays.

Two run-modes:
    server.py refresh   — aggregate every source, write state.json + XMLTV.
                          Invoked by unified-guide-refresh.timer.
    server.py serve     — HTTP server reading state.json. Invoked by
                          unified-guide.service.

Stdlib only — no pip deps. Configuration via /etc/unified-guide/env (sourced
by systemd) or environment variables; see UNIFIED-EPG.md for the full list.
"""
from __future__ import annotations

import json
import logging
import os
import re
import socket
import ssl
import sys
import threading
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

# ──────────────────────────────────────────────────────────────────────────────
# config
# ──────────────────────────────────────────────────────────────────────────────
CFG = {
    # output / cache
    "STATE_FILE":      os.environ.get("UG_STATE_FILE", "/var/cache/unified-guide/state.json"),
    "UNIFIED_XMLTV":   os.environ.get("UG_UNIFIED_XMLTV", "/data/streaming/unified.xml"),
    "STATIC_DIR":      os.environ.get("UG_STATIC_DIR", "/opt/unified-guide/static"),
    # bind
    "BIND_HOST":       os.environ.get("UG_BIND_HOST", "0.0.0.0"),
    "BIND_PORT":       int(os.environ.get("UG_BIND_PORT", "7700")),
    # source: zap2xml OTA
    "OTA_XMLTV":       os.environ.get("UG_OTA_XMLTV", "/data/media/epg.xml"),
    # source: Threadfin (IPTV M3U+XMLTV merged through it)
    "THREADFIN_URL":   os.environ.get("UG_THREADFIN_URL", "http://127.0.0.1:34400"),
    "THREADFIN_XMLTV": os.environ.get("UG_THREADFIN_XMLTV", ""),  # optional override
    # source: YouTube TV scraper outputs
    "YTTV_CHANNELS":   os.environ.get("UG_YTTV_CHANNELS", "/data/streaming/yttv/yttv-channels.json"),
    "YTTV_EPG":        os.environ.get("UG_YTTV_EPG", "/data/streaming/yttv/yttv-epg.xml"),
    # source: TMDB watch-providers (SVOD lanes)
    "TMDB_API_KEY":    os.environ.get("UG_TMDB_API_KEY", ""),
    "TMDB_REGION":     os.environ.get("UG_TMDB_REGION", "US"),
    "TMDB_PROVIDERS":  os.environ.get("UG_TMDB_PROVIDERS",
                                     "Netflix:8,Amazon:9,Max:1899,Disney+:337,Peacock:386"),
    "TMDB_LIMIT":      int(os.environ.get("UG_TMDB_LIMIT", "30")),
    # source: Jellyfin local library
    "JELLYFIN_URL":    os.environ.get("UG_JELLYFIN_URL", "http://127.0.0.1:8096"),
    "JELLYFIN_TOKEN":  os.environ.get("UG_JELLYFIN_TOKEN", ""),
    "JELLYFIN_PUBLIC": os.environ.get("UG_JELLYFIN_PUBLIC", "https://jellyfin.mediastack.lan"),
    "JELLYFIN_LIB_LIMIT": int(os.environ.get("UG_JELLYFIN_LIB_LIMIT", "50")),
    # Riven request UI (closes the loop: see-it-on-SVOD -> ingest via RD -> JD2 -> Jellyfin)
    "RIVEN_PUBLIC":    os.environ.get("UG_RIVEN_PUBLIC", "https://riven.mediastack.lan"),
    # behavior
    "REFRESH_TIMEOUT": int(os.environ.get("UG_REFRESH_TIMEOUT", "20")),
}

logging.basicConfig(
    level=os.environ.get("UG_LOG_LEVEL", "INFO"),
    format="%(asctime)s [unified-guide] %(levelname)s %(message)s",
)
log = logging.getLogger("unified-guide")

# ──────────────────────────────────────────────────────────────────────────────
# helpers
# ──────────────────────────────────────────────────────────────────────────────
def http_get(url: str, headers: Optional[Dict[str, str]] = None,
             timeout: int = None) -> bytes:
    timeout = timeout or CFG["REFRESH_TIMEOUT"]
    req = urllib.request.Request(url, headers=headers or {})
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return r.read()


def http_get_json(url: str, headers: Optional[Dict[str, str]] = None,
                  timeout: int = None) -> Any:
    return json.loads(http_get(url, headers, timeout).decode("utf-8"))


def parse_xmltv_time(s: str) -> Optional[datetime]:
    if not s:
        return None
    # XMLTV: 20240108130000 -0500  or  20240108130000+0000
    s = s.strip()
    try:
        if " " in s:
            stamp, off = s.split(" ", 1)
        else:
            # detect trailing +/-
            m = re.match(r"^(\d{14})([+-]\d{4})$", s)
            if not m:
                return datetime.strptime(s[:14], "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)
            stamp, off = m.group(1), m.group(2)
        sign = 1 if off[0] == "+" else -1
        off_h, off_m = int(off[1:3]), int(off[3:5])
        tz = timezone(sign * timedelta(hours=off_h, minutes=off_m))
        return datetime.strptime(stamp, "%Y%m%d%H%M%S").replace(tzinfo=tz)
    except Exception as e:
        log.debug("bad xmltv time %r: %s", s, e)
        return None


def fmt_xmltv(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    base = dt.strftime("%Y%m%d%H%M%S")
    off = dt.strftime("%z")
    return f"{base} {off}"


def slugify(s: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()
    return s or "x"


# ──────────────────────────────────────────────────────────────────────────────
# data model
# ──────────────────────────────────────────────────────────────────────────────
def riven_request_url(title: str) -> str:
    """Deep-link to Riven's explore/search page for the given title."""
    base = CFG.get("RIVEN_PUBLIC", "").rstrip("/")
    if not base or not title:
        return ""
    return f"{base}/explore?query={urllib.parse.quote(title)}"


def make_record(*, source: str, channel_id: str, channel_name: str,
                title: str, start: Optional[datetime], stop: Optional[datetime],
                desc: str = "", launch_url: str = "",
                icon: str = "", category: str = "") -> Dict[str, Any]:
    # request_url is empty for the local library (already in your library) — for
    # everything else (linear airings, SVOD discovery), expose a one-click path
    # to ask Riven to ingest it via Real-Debrid -> JDownloader2 -> Jellyfin.
    req = "" if source == "local" else riven_request_url(title)
    return {
        "source": source,
        "channel_id": channel_id,
        "channel_name": channel_name,
        "title": title,
        "desc": desc,
        "start": start.isoformat() if start else None,
        "stop":  stop.isoformat()  if stop  else None,
        "launch_url": launch_url,
        "request_url": req,
        "icon": icon,
        "category": category,
    }


# ──────────────────────────────────────────────────────────────────────────────
# source: Jellyfin (used for live-tv channel-id resolution + library lane)
# ──────────────────────────────────────────────────────────────────────────────
def jellyfin_channels() -> Tuple[str, Dict[str, str]]:
    """Returns (server_id, {channel_name_lc: channel_id})."""
    url = CFG["JELLYFIN_URL"]
    tok = CFG["JELLYFIN_TOKEN"]
    if not tok:
        return "", {}
    headers = {"X-Emby-Token": tok}
    sid = ""
    try:
        info = http_get_json(f"{url}/System/Info/Public", headers=headers, timeout=8)
        sid = info.get("Id", "")
    except Exception as e:
        log.warning("jellyfin info: %s", e)
        return "", {}
    name_to_id: Dict[str, str] = {}
    try:
        d = http_get_json(f"{url}/LiveTv/Channels?limit=2000",
                          headers=headers, timeout=15)
        for c in d.get("Items", []):
            n = (c.get("Name") or "").strip().lower()
            i = c.get("Id") or ""
            if n and i:
                name_to_id[n] = i
    except Exception as e:
        log.warning("jellyfin live-tv channels: %s", e)
    return sid, name_to_id


def jellyfin_launch_for_channel(server_id: str, channel_id: str) -> str:
    return (f"{CFG['JELLYFIN_PUBLIC']}/web/index.html"
            f"#/details?id={channel_id}&context=livetv&serverId={server_id}")


def jellyfin_launch_for_item(server_id: str, item_id: str) -> str:
    return (f"{CFG['JELLYFIN_PUBLIC']}/web/index.html"
            f"#/details?id={item_id}&serverId={server_id}")


def from_jellyfin_library(server_id: str) -> List[Dict[str, Any]]:
    tok = CFG["JELLYFIN_TOKEN"]
    if not tok:
        return []
    headers = {"X-Emby-Token": tok}
    out: List[Dict[str, Any]] = []
    try:
        url = (f"{CFG['JELLYFIN_URL']}/Items?Recursive=true"
               f"&IncludeItemTypes=Movie,Series"
               f"&SortBy=DateCreated&SortOrder=Descending"
               f"&Limit={CFG['JELLYFIN_LIB_LIMIT']}"
               f"&Fields=Overview,PrimaryImageAspectRatio")
        d = http_get_json(url, headers=headers, timeout=15)
        for it in d.get("Items", []):
            iid = it.get("Id") or ""
            name = it.get("Name") or ""
            if not (iid and name):
                continue
            icon = ""
            if it.get("ImageTags", {}).get("Primary"):
                icon = (f"{CFG['JELLYFIN_PUBLIC']}/Items/{iid}/Images/Primary"
                        f"?tag={it['ImageTags']['Primary']}&maxHeight=200")
            out.append(make_record(
                source="local",
                channel_id="local-library",
                channel_name="Your Library",
                title=name,
                start=None, stop=None,
                desc=it.get("Overview", ""),
                launch_url=jellyfin_launch_for_item(server_id, iid),
                icon=icon,
                category=it.get("Type", ""),
            ))
    except Exception as e:
        log.warning("jellyfin library: %s", e)
    return out


# ──────────────────────────────────────────────────────────────────────────────
# source: XMLTV linear feeds (zap2xml OTA, Threadfin IPTV, YT TV)
# ──────────────────────────────────────────────────────────────────────────────
def parse_xmltv_file(path: str) -> Tuple[Dict[str, Dict[str, str]],
                                          List[Dict[str, str]]]:
    """Returns ({channel_id: {name, icon}}, [{channel_id, title, desc, start, stop}])."""
    if not path or not os.path.isfile(path):
        return {}, []
    try:
        tree = ET.parse(path)
    except Exception as e:
        log.warning("xmltv parse %s: %s", path, e)
        return {}, []
    root = tree.getroot()
    chans: Dict[str, Dict[str, str]] = {}
    progs: List[Dict[str, str]] = []
    for c in root.findall("channel"):
        cid = c.get("id") or ""
        if not cid:
            continue
        name_el = c.find("display-name")
        icon_el = c.find("icon")
        chans[cid] = {
            "name": (name_el.text or "").strip() if name_el is not None else cid,
            "icon": icon_el.get("src", "") if icon_el is not None else "",
        }
    for p in root.findall("programme"):
        cid = p.get("channel") or ""
        title_el = p.find("title")
        desc_el  = p.find("desc")
        progs.append({
            "channel_id": cid,
            "title": (title_el.text or "").strip() if title_el is not None else "",
            "desc":  (desc_el.text  or "").strip() if desc_el  is not None else "",
            "start": p.get("start", ""),
            "stop":  p.get("stop", ""),
        })
    return chans, progs


def xmltv_to_records(path: str, source: str, server_id: str,
                     name_to_jf: Dict[str, str],
                     yttv_video_map: Optional[Dict[str, str]] = None) -> List[Dict[str, Any]]:
    chans, progs = parse_xmltv_file(path)
    if not chans:
        return []
    out: List[Dict[str, Any]] = []
    for p in progs:
        cid = p["channel_id"]
        ch = chans.get(cid, {"name": cid, "icon": ""})
        cname = ch["name"]
        # launch URL strategy:
        if source == "yttv" and yttv_video_map:
            vid = yttv_video_map.get(cname.upper().strip()) or yttv_video_map.get(cid)
            launch = f"https://tv.youtube.com/watch/{vid}" if vid else "https://tv.youtube.com/live"
        else:
            jf_id = name_to_jf.get(cname.lower().strip()) if name_to_jf else None
            if jf_id and server_id:
                launch = jellyfin_launch_for_channel(server_id, jf_id)
            else:
                launch = f"{CFG['JELLYFIN_PUBLIC']}/web/index.html#/livetv?tab=1&serverId={server_id}"
        out.append(make_record(
            source=source,
            channel_id=cid,
            channel_name=cname,
            title=p["title"],
            start=parse_xmltv_time(p["start"]),
            stop=parse_xmltv_time(p["stop"]),
            desc=p["desc"],
            launch_url=launch,
            icon=ch["icon"],
        ))
    return out


# ──────────────────────────────────────────────────────────────────────────────
# source: TMDB watch-providers (SVOD virtual lanes)
# ──────────────────────────────────────────────────────────────────────────────
SVOD_SEARCH_TPL = {
    "Netflix":  "https://www.netflix.com/search?q={q}",
    "Amazon":   "https://www.amazon.com/s?k={q}&i=instant-video",
    "Max":      "https://play.max.com/search?q={q}",
    "Disney+":  "https://www.disneyplus.com/search?q={q}",
    "Peacock":  "https://www.peacocktv.com/search?q={q}",
}


def parse_providers_cfg(cfg: str) -> List[Tuple[str, str]]:
    out = []
    for piece in cfg.split(","):
        if ":" not in piece:
            continue
        n, pid = piece.split(":", 1)
        out.append((n.strip(), pid.strip()))
    return out


def from_tmdb_svod() -> List[Dict[str, Any]]:
    key = CFG["TMDB_API_KEY"]
    if not key:
        log.info("TMDB_API_KEY not set; SVOD lanes disabled")
        return []
    region = CFG["TMDB_REGION"]
    limit = CFG["TMDB_LIMIT"]
    out: List[Dict[str, Any]] = []
    for prov_name, prov_id in parse_providers_cfg(CFG["TMDB_PROVIDERS"]):
        for kind in ("tv", "movie"):
            try:
                url = (f"https://api.themoviedb.org/3/discover/{kind}"
                       f"?api_key={key}&watch_region={region}"
                       f"&with_watch_providers={prov_id}"
                       f"&sort_by=popularity.desc&page=1")
                d = http_get_json(url, timeout=12)
            except Exception as e:
                log.warning("tmdb %s/%s: %s", prov_name, kind, e)
                continue
            for item in (d.get("results") or [])[:limit]:
                title = item.get("title") or item.get("name") or ""
                if not title:
                    continue
                tpl = SVOD_SEARCH_TPL.get(prov_name)
                if not tpl:
                    continue
                launch = tpl.format(q=urllib.parse.quote(title))
                icon = ""
                if item.get("poster_path"):
                    icon = f"https://image.tmdb.org/t/p/w200{item['poster_path']}"
                out.append(make_record(
                    source="svod",
                    channel_id=f"svod-{slugify(prov_name)}",
                    channel_name=prov_name,
                    title=title,
                    start=None, stop=None,
                    desc=item.get("overview", ""),
                    launch_url=launch,
                    icon=icon,
                    category=kind,
                ))
    return out


# ──────────────────────────────────────────────────────────────────────────────
# unified XMLTV writer (linear sources only — SVOD/local omitted, no schedule)
# ──────────────────────────────────────────────────────────────────────────────
def write_unified_xmltv(records: List[Dict[str, Any]], out_path: str) -> None:
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    seen_chans: Dict[str, str] = {}
    tv = ET.Element("tv", {
        "generator-info-name": "bulletproof-mediastack/unified-guide",
        "source-info-name":    "merged: zap2xml + threadfin + yttv",
    })
    # First pass: channel definitions
    for r in records:
        if r["source"] not in ("ota", "iptv", "yttv"):
            continue
        cid = r["channel_id"]  # raw ID — matches tvg-id in M3U and Jellyfin tuner
        if cid in seen_chans:
            continue
        seen_chans[cid] = r["channel_name"]
        c = ET.SubElement(tv, "channel", {"id": cid})
        ET.SubElement(c, "display-name").text = r["channel_name"]
        if r.get("icon"):
            ET.SubElement(c, "icon", {"src": r["icon"]})
    # Second pass: programmes
    for r in records:
        if r["source"] not in ("ota", "iptv", "yttv"):
            continue
        if not (r["start"] and r["stop"]):
            continue
        try:
            s = datetime.fromisoformat(r["start"])
            e = datetime.fromisoformat(r["stop"])
        except Exception:
            continue
        cid = r["channel_id"]  # raw ID
        p = ET.SubElement(tv, "programme", {
            "channel": cid,
            "start":   fmt_xmltv(s),
            "stop":    fmt_xmltv(e),
        })
        ET.SubElement(p, "title").text = r["title"] or ""
        if r.get("desc"):
            ET.SubElement(p, "desc").text = r["desc"]
    tree = ET.ElementTree(tv)
    tmp = out_path + f".{os.getpid()}.tmp"
    tree.write(tmp, encoding="utf-8", xml_declaration=True)
    os.replace(tmp, out_path)
    log.info("wrote %s (%d channels, %d programmes)",
             out_path, len(seen_chans),
             len([1 for r in records if r["source"] in ("ota", "iptv", "yttv")
                  and r["start"] and r["stop"]]))


# ──────────────────────────────────────────────────────────────────────────────
# refresh
# ──────────────────────────────────────────────────────────────────────────────
def refresh() -> Dict[str, Any]:
    started = time.time()
    server_id, name_to_jf = jellyfin_channels()
    log.info("jellyfin: server_id=%s, %d live-tv channels",
             server_id or "(none)", len(name_to_jf))

    records: List[Dict[str, Any]] = []

    # OTA via zap2xml
    ota = xmltv_to_records(CFG["OTA_XMLTV"], "ota", server_id, name_to_jf)
    log.info("OTA  records: %d (from %s)", len(ota), CFG["OTA_XMLTV"])
    records += ota

    # IPTV via Threadfin XMLTV (if configured)
    th_xml = CFG["THREADFIN_XMLTV"]
    # If the override is a remote URL, download it to a local cache first
    if th_xml and th_xml.startswith(("http://", "https://")):
        try:
            data = http_get(th_xml, timeout=20)
            cache = "/var/cache/unified-guide/threadfin.xml"
            Path(cache).parent.mkdir(parents=True, exist_ok=True)
            with open(cache, "wb") as f:
                f.write(data)
            th_xml = cache
            log.info("threadfin xmltv (URL override) cached to %s", cache)
        except Exception as e:
            log.info("threadfin xmltv (URL override) unavailable (%s); skipping", e)
            th_xml = ""
    if not th_xml and CFG["THREADFIN_URL"]:
        # Threadfin default xmltv path: /xmltv/threadfin.xml
        th_xml = CFG["THREADFIN_URL"].rstrip("/") + "/xmltv/threadfin.xml"
        # If remote URL: download to a temp file
        try:
            data = http_get(th_xml, timeout=15)
            cache = "/var/cache/unified-guide/threadfin.xml"
            Path(cache).parent.mkdir(parents=True, exist_ok=True)
            with open(cache, "wb") as f:
                f.write(data)
            th_xml = cache
        except Exception as e:
            log.info("threadfin xmltv unavailable (%s); skipping", e)
            th_xml = ""
    if th_xml:
        iptv = xmltv_to_records(th_xml, "iptv", server_id, name_to_jf)
        log.info("IPTV records: %d", len(iptv))
        records += iptv

    # YouTube TV
    yttv_video_map: Dict[str, str] = {}
    yttv_chan_path = CFG["YTTV_CHANNELS"]
    if os.path.isfile(yttv_chan_path):
        try:
            j = json.loads(open(yttv_chan_path).read())
            for c in j.get("channels", []):
                if c.get("name") and c.get("video_id"):
                    yttv_video_map[c["name"].upper().strip()] = c["video_id"]
        except Exception as e:
            log.warning("yttv channels: %s", e)
    if os.path.isfile(CFG["YTTV_EPG"]):
        yttv = xmltv_to_records(CFG["YTTV_EPG"], "yttv", server_id, name_to_jf,
                                yttv_video_map=yttv_video_map)
        log.info("YTTV records: %d", len(yttv))
        records += yttv
    elif yttv_video_map:
        # No EPG, but we have channels — synthesize "Now" cells
        now = datetime.now(timezone.utc)
        plus3 = now + timedelta(hours=3)
        for name, vid in yttv_video_map.items():
            records.append(make_record(
                source="yttv",
                channel_id=slugify(name),
                channel_name=name,
                title="Live on YouTube TV",
                start=now, stop=plus3,
                launch_url=f"https://tv.youtube.com/watch/{vid}",
            ))
        log.info("YTTV records (synthetic): %d", len(yttv_video_map))

    # SVOD via TMDB
    svod = from_tmdb_svod()
    log.info("SVOD records: %d", len(svod))
    records += svod

    # Local Jellyfin library
    lib = from_jellyfin_library(server_id)
    log.info("Library records: %d", len(lib))
    records += lib

    # Write XMLTV (linear only)
    write_unified_xmltv(records, CFG["UNIFIED_XMLTV"])

    # Persist state for serve mode
    state = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "server_id": server_id,
        "counts": {
            "ota": sum(1 for r in records if r["source"] == "ota"),
            "iptv": sum(1 for r in records if r["source"] == "iptv"),
            "yttv": sum(1 for r in records if r["source"] == "yttv"),
            "svod": sum(1 for r in records if r["source"] == "svod"),
            "local": sum(1 for r in records if r["source"] == "local"),
        },
        "records": records,
    }
    Path(CFG["STATE_FILE"]).parent.mkdir(parents=True, exist_ok=True)
    tmp = CFG["STATE_FILE"] + f".{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, separators=(",", ":"))
    os.replace(tmp, CFG["STATE_FILE"])
    log.info("refresh complete in %.1fs: %s", time.time() - started, state["counts"])
    return state


# ──────────────────────────────────────────────────────────────────────────────
# HTTP server
# ──────────────────────────────────────────────────────────────────────────────
def load_state() -> Dict[str, Any]:
    try:
        with open(CFG["STATE_FILE"]) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"records": [], "counts": {}, "generated_at": None}
    except Exception as e:
        log.warning("state.json bad: %s", e)
        return {"records": [], "counts": {}, "generated_at": None, "error": str(e)}


class Handler(BaseHTTPRequestHandler):
    server_version = "unified-guide/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        log.debug("%s - %s", self.address_string(), fmt % args)

    def _send(self, code: int, body: bytes, ctype: str,
              extra_headers: Optional[Dict[str, str]] = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, code: int, obj: Any) -> None:
        self._send(code, json.dumps(obj).encode("utf-8"), "application/json")

    def _send_file(self, path: str, ctype: str) -> None:
        try:
            with open(path, "rb") as f:
                self._send(200, f.read(), ctype)
        except FileNotFoundError:
            self._send(404, b"not found", "text/plain")

    def do_GET(self) -> None:
        u = urllib.parse.urlparse(self.path)
        if u.path in ("/", "/index.html"):
            self._send_file(os.path.join(CFG["STATIC_DIR"], "index.html"), "text/html; charset=utf-8")
        elif u.path.startswith("/static/"):
            sub = u.path[len("/static/"):]
            if "/" in sub or ".." in sub:
                return self._send(400, b"bad path", "text/plain")
            ext = sub.rsplit(".", 1)[-1].lower()
            ctype = {
                "css": "text/css", "js": "application/javascript",
                "html": "text/html", "json": "application/json",
                "svg": "image/svg+xml", "png": "image/png", "ico": "image/x-icon",
            }.get(ext, "application/octet-stream")
            self._send_file(os.path.join(CFG["STATIC_DIR"], sub), ctype)
        elif u.path == "/api/grid":
            self._send_json(200, load_state())
        elif u.path == "/api/health":
            self._send_json(200, {"ok": True, "ts": time.time()})
        elif u.path == "/healthz":
            self._send(200, b"ok\n", "text/plain")
        else:
            self._send(404, b"not found", "text/plain")

    def do_POST(self) -> None:
        if urllib.parse.urlparse(self.path).path == "/api/refresh":
            t = threading.Thread(target=refresh, daemon=True)
            t.start()
            self._send_json(202, {"started": True})
        else:
            self._send(404, b"not found", "text/plain")


def serve() -> None:
    httpd = ThreadingHTTPServer((CFG["BIND_HOST"], CFG["BIND_PORT"]), Handler)
    log.info("serving on http://%s:%d", CFG["BIND_HOST"], CFG["BIND_PORT"])
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


# ──────────────────────────────────────────────────────────────────────────────
# entry point
# ──────────────────────────────────────────────────────────────────────────────
def main() -> int:
    if len(sys.argv) < 2:
        print("usage: server.py {refresh|serve}", file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    if cmd == "refresh":
        refresh()
        return 0
    if cmd == "serve":
        # background refresh on startup so the first GET has data
        threading.Thread(target=lambda: (time.sleep(2), refresh()), daemon=True).start()
        serve()
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
