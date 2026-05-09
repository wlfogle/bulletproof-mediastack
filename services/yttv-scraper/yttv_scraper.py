#!/usr/bin/env python3
"""
yttv-scraper — parses a YouTube TV web `browse.json` (staged from a logged-in
browser session) into:

    /data/streaming/yttv/yttv-channels.json   — name -> videoId mapping
    /data/streaming/yttv/yttv.m3u             — M3U playlist (placeholder URLs)
    /data/streaming/yttv/yttv-epg.xml         — XMLTV (channels + airings)

Extraction path follows the TarheelGrad1998/ha-tv contract:
  contents.epgRenderer.paginationRenderer.epgPaginationRenderer.contents[]
    epgRowRenderer.station.epgStationRenderer.icon.accessibility.accessibilityData.label
    epgRowRenderer.airings[*].epgAiringRenderer.{title,startTime,endTime,
      navigationEndpoint.watchEndpoint.videoId}

YouTube TV's /youtubei/v1/unplugged/browse endpoint is bot-walled, so the
operator stages browse.json from a logged-in browser session (see
docs/UNIFIED-EPG.md for the cookie/refresh procedure). Cookie-based scraping
direct from the API is intentionally NOT implemented here — it gets blocked
within minutes — and would put the whole pipeline at risk for reliability.

Stdlib only.
"""
from __future__ import annotations

import json
import logging
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

INPUT_PATH  = os.environ.get("YTTV_BROWSE_JSON", "/var/lib/yttv-scraper/browse.json")
OUTPUT_DIR  = os.environ.get("YTTV_OUTPUT_DIR", "/data/streaming/yttv")
M3U_PATH    = os.path.join(OUTPUT_DIR, "yttv.m3u")
EPG_PATH    = os.path.join(OUTPUT_DIR, "yttv-epg.xml")
CHAN_PATH   = os.path.join(OUTPUT_DIR, "yttv-channels.json")
WATCH_BASE  = os.environ.get("YTTV_WATCH_BASE", "https://tv.youtube.com/watch")

logging.basicConfig(
    level=os.environ.get("YTTV_LOG_LEVEL", "INFO"),
    format="%(asctime)s [yttv-scraper] %(levelname)s %(message)s",
)
log = logging.getLogger("yttv-scraper")


def get(d: Any, *keys: Any, default: Any = None) -> Any:
    """Tolerant nested-dict accessor."""
    cur = d
    for k in keys:
        if cur is None:
            return default
        if isinstance(k, int):
            if isinstance(cur, list) and -len(cur) <= k < len(cur):
                cur = cur[k]
            else:
                return default
        else:
            if isinstance(cur, dict):
                cur = cur.get(k)
            else:
                return default
    return cur if cur is not None else default


def slugify(s: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()
    return s or "x"


def parse_youtube_iso(s: Optional[str]) -> Optional[datetime]:
    """YouTube returns ISO-8601 like 2024-05-09T03:00:00Z or with offset."""
    if not s:
        return None
    try:
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        return datetime.fromisoformat(s)
    except Exception as e:
        log.debug("bad iso time %r: %s", s, e)
        return None


def fmt_xmltv(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.strftime("%Y%m%d%H%M%S %z")


def extract_channels(browse: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Returns a list of {name, video_id, icon, airings:[{title,start,end,video_id,desc}]}."""
    rows = get(browse, "contents", "epgRenderer", "paginationRenderer",
               "epgPaginationRenderer", "contents", default=[])
    if not rows:
        # Older / alternate path observed in some captures
        rows = get(browse, "contents", "epgRenderer", "contents", default=[])
    out: List[Dict[str, Any]] = []
    for row in rows or []:
        epg_row = get(row, "epgRowRenderer")
        if not epg_row:
            continue
        # Channel name
        name = get(epg_row, "station", "epgStationRenderer", "icon",
                   "accessibility", "accessibilityData", "label")
        if not name:
            name = get(epg_row, "station", "epgStationRenderer", "title", "simpleText", default="")
        name = (name or "").strip().upper()
        if not name:
            continue
        # Channel logo (when present)
        icon = ""
        thumbs = get(epg_row, "station", "epgStationRenderer", "icon",
                     "thumbnails", default=[]) or \
                 get(epg_row, "station", "epgStationRenderer", "thumbnail",
                     "thumbnails", default=[])
        if thumbs:
            icon = thumbs[-1].get("url", "")
            if icon.startswith("//"):
                icon = "https:" + icon
        # Default channel videoId = first airing
        airings = epg_row.get("airings", []) or []
        first_vid = (
            get(airings, 0, "epgAiringRenderer", "navigationEndpoint",
                "watchEndpoint", "videoId")
            or get(airings, 0, "epgAiringRenderer", "navigationEndpoint",
                "unpluggedPopupEndpoint", "popupRenderer",
                "unpluggedSelectionMenuDialogRenderer", "items", 0,
                "unpluggedMenuItemRenderer", "command", "watchEndpoint",
                "videoId")
            or ""
        )
        # Airings list
        ev: List[Dict[str, Any]] = []
        for a in airings:
            r = a.get("epgAiringRenderer") or {}
            title = (
                get(r, "title", "simpleText")
                or get(r, "title", "runs", 0, "text")
                or ""
            )
            start = parse_youtube_iso(get(r, "startTime") or get(r, "startTimestamp"))
            end   = parse_youtube_iso(get(r, "endTime")   or get(r, "endTimestamp"))
            vid = (get(r, "navigationEndpoint", "watchEndpoint", "videoId")
                   or first_vid)
            desc = (get(r, "description", "simpleText")
                    or get(r, "shortDescription", "simpleText") or "")
            if title and start and end:
                ev.append({
                    "title": title.strip(),
                    "start": start, "end": end,
                    "video_id": vid, "desc": desc.strip(),
                })
        out.append({
            "name": name,
            "video_id": first_vid,
            "icon": icon,
            "airings": ev,
        })
    return out


def write_outputs(channels: List[Dict[str, Any]]) -> Tuple[int, int]:
    Path(OUTPUT_DIR).mkdir(parents=True, exist_ok=True)

    # 1. JSON channels file (consumed by unified-guide for launch URLs)
    chan_dump = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "channels": [
            {"name": c["name"], "video_id": c["video_id"], "icon": c["icon"]}
            for c in channels if c["video_id"]
        ],
    }
    with open(CHAN_PATH + ".tmp", "w") as f:
        json.dump(chan_dump, f, indent=2)
    os.replace(CHAN_PATH + ".tmp", CHAN_PATH)

    # 2. M3U
    lines = ["#EXTM3U"]
    for c in channels:
        if not c["video_id"]:
            continue
        ch_id = slugify(c["name"])
        logo = f' tvg-logo="{c["icon"]}"' if c["icon"] else ""
        lines.append(f'#EXTINF:-1 tvg-id="{ch_id}" tvg-name="{c["name"]}"{logo}'
                     f' group-title="YouTube TV",{c["name"]}')
        # We don't have a playable HLS URL — point at the YT TV watch page so
        # any player that can open URLs (Jellyfin Live TV via Threadfin will
        # ignore this; the unified-guide grid uses this for click handoff).
        lines.append(f"{WATCH_BASE}/{c['video_id']}")
    with open(M3U_PATH + ".tmp", "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(M3U_PATH + ".tmp", M3U_PATH)

    # 3. XMLTV
    tv = ET.Element("tv", {
        "generator-info-name": "bulletproof-mediastack/yttv-scraper",
        "source-info-name": "tv.youtube.com browse.json",
    })
    for c in channels:
        ch_id = slugify(c["name"])
        ch_el = ET.SubElement(tv, "channel", {"id": ch_id})
        ET.SubElement(ch_el, "display-name").text = c["name"]
        if c["icon"]:
            ET.SubElement(ch_el, "icon", {"src": c["icon"]})
    prog_count = 0
    for c in channels:
        ch_id = slugify(c["name"])
        for a in c["airings"]:
            p = ET.SubElement(tv, "programme", {
                "channel": ch_id,
                "start": fmt_xmltv(a["start"]),
                "stop":  fmt_xmltv(a["end"]),
            })
            ET.SubElement(p, "title").text = a["title"]
            if a["desc"]:
                ET.SubElement(p, "desc").text = a["desc"]
            prog_count += 1
    tree = ET.ElementTree(tv)
    tree.write(EPG_PATH + ".tmp", encoding="utf-8", xml_declaration=True)
    os.replace(EPG_PATH + ".tmp", EPG_PATH)
    return len(channels), prog_count


def main() -> int:
    if not os.path.isfile(INPUT_PATH):
        log.error("staged browse.json not found at %s — see docs/UNIFIED-EPG.md "
                  "for the cookie/refresh procedure", INPUT_PATH)
        return 1
    try:
        with open(INPUT_PATH) as f:
            browse = json.load(f)
    except Exception as e:
        log.error("parse %s: %s", INPUT_PATH, e)
        return 2
    channels = extract_channels(browse)
    if not channels:
        log.error("no channels parsed from %s — staged file may be stale or "
                  "the YouTube TV schema has shifted", INPUT_PATH)
        return 3
    nc, np = write_outputs(channels)
    log.info("wrote %d channels / %d programmes -> %s",
             nc, np, OUTPUT_DIR)
    return 0


if __name__ == "__main__":
    sys.exit(main())
