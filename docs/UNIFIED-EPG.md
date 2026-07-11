# Unified EPG (CT-300)
One grid, every source, click → the right app launches and plays.
## What you get
A single web page at `https://guide.mediastack.lan/` (and `http://192.168.12.30:7700/` as the LAN-IP fallback) that aggregates every viewable source on the stack into one TV-grid:
- **OTA** lanes from the existing `zap2xml` output at `/data/media/epg.xml`.
- **IPTV** lanes from Threadfin's XMLTV (TVPass).
- **YouTube TV** lanes from a staged `browse.json` (cookie-based scrape).
- **SVOD** virtual lanes for **Netflix, Max, Disney+, Peacock**, populated from TMDB's JustWatch-backed `watch/providers` endpoint.
- **Your Library** lane from Jellyfin `/Items` (recently added + Next Up).

Each cell carries a single launch URL chosen by source type:
- OTA / IPTV → Jellyfin Live TV channel URL → Jellyfin opens and tunes.
- YouTube TV → `https://tv.youtube.com/watch/<videoId>` → YouTube TV app/site opens already tuned to that channel.
- SVOD → vendor search URL (Netflix / Max / Disney+ / Peacock) → vendor app opens to that title.
- Local library → Jellyfin item URL → Jellyfin opens the item.

Every cell also has a small `+` badge in the top-right that opens **Riven**'s request UI for that title — closing the loop: see-it-on-SVOD → request → Real-Debrid → JD2 → it appears in the Library lane next refresh. Right-click on a cell does the same.

## Component layout
All native systemd services in CT-300 (no Docker):
- `unified-guide.service` — Python stdlib HTTP server on `:7700`, reads `/var/cache/unified-guide/state.json`.
- `unified-guide-refresh.service` (oneshot) — aggregates every source, writes `state.json` + `/data/streaming/unified.xml` (XMLTV merge of linear sources for Jellyfin Live TV).
- `unified-guide-refresh.timer` — every 15 min.
- `yttv-scraper.service` (oneshot) — parses `/var/lib/yttv-scraper/browse.json` into `/data/streaming/yttv/{yttv.m3u, yttv-epg.xml, yttv-channels.json}`.
- `yttv-scraper.timer` — every 30 min.



On the **Tiamat host**:
- `disk-space-watchdog.service` (oneshot) — pauses Riven→JD2 + qBit + evicts hardlinked torrent copies when `/mnt/hdd` exceeds the threshold; cleans `/` (journal, apt, pnpm, vzdump prune) when SSD pressure builds.
- `disk-space-watchdog.timer` — every 5 min.

Caddy on CT-300 has been updated with:
```
guide.mediastack.lan, guide.local {
    tls internal
    import headers
    reverse_proxy 127.0.0.1:7700
}
```
## Install / re-deploy
```
ssh tiamat 'cd ~/bulletproof-mediastack && git pull'
bash scripts/install-unified-guide.sh
```
The script is idempotent. It always:
1. Self-tests (`bash -n`, `shellcheck`).
2. Preflight (Tiamat reachable, CT-300 running, Jellyfin :8096 listening).
3. **Discovers** the TMDB API key from the n8n Variables table in CT-300 (CT-242 Jellyseerr is decommissioned — key was migrated to CT-300). Discovers the Jellyfin token from CT-300's existing `/etc/jellyfin-autoscan.env`. Riven public URL is constant (`https://riven.mediastack.lan`).
4. Pushes `services/unified-guide/` and `services/yttv-scraper/` into CT-300 via tar+pct push.
5. Writes `/etc/unified-guide/env` (mode 0600) — preserved across re-runs.
6. Generates `yttv-scraper.{service,timer}` inline.
7. Adds the Caddy site block (idempotent — won't duplicate).
8. Installs Tailscale **inside** CT-300 (`--accept-dns=false` so AdGuard remains the resolver for `*.mediastack.lan`).
9. Enables/starts every unit.
10. Installs `disk-space-watchdog` on the Tiamat host with a 5 min timer.
11. Verifies HTTP 200 on `http://192.168.12.30:7700/` and prints both URLs.
## YouTube TV cookie / browse.json refresh
YouTube TV's `/youtubei/v1/unplugged/browse` endpoint is bot-walled — calling it directly with curl + cookies gets blocked within minutes. We stage `browse.json` from a logged-in browser session instead. Procedure:
1. On a desktop browser logged into `tv.youtube.com`, open Dev Tools → Network tab.
2. Visit `tv.youtube.com/live`.
3. Find the `browse` request (POST to `/youtubei/v1/unplugged/browse`).
4. Right-click → Save response → save as `browse.json`.
5. Copy onto Tiamat host: `scp browse.json tiamat:/tmp/`
6. Push into CT-300: `ssh tiamat 'pct push 300 /tmp/browse.json /var/lib/yttv-scraper/browse.json'`
7. The next `yttv-scraper.timer` tick (within 30 min) parses it, or trigger immediately: `ssh tiamat 'pct exec 300 -- systemctl start yttv-scraper.service'`

Cookies typically remain valid for 7–14 days. Re-stage when the YouTube TV lane on the guide goes stale or the scraper logs `staged file may be stale or schema shifted`.
## Jellyfin Live TV merge
The unified-guide refresh writes `/data/streaming/unified.xml` with every linear source merged. To make Jellyfin's own Live TV grid show this same merged guide:
1. Jellyfin Dashboard → **Live TV → TV Guide Data Providers** → Add **XMLTV**.
2. Path: `/data/streaming/unified.xml`. URL refresh interval: 15 min (matches our timer).
3. Save → run a **Live TV** scan from the dashboard.

Jellyfin will now show OTA + IPTV + YouTube TV channels in the same EPG. **YouTube TV channels appear in Jellyfin's grid but are not playable inside Jellyfin** — clicking them in Jellyfin's Live TV does nothing useful because YT TV's stream is DRM-protected. To play YT TV channels, use the unified guide at `guide.mediastack.lan` instead — those clicks deep-link to the YouTube TV app/web.
## Disk-space watchdog action ladder
| Resource | Threshold | Action |
|---|---|---|
| `/mnt/hdd` ≥ 80% | warn | evict torrents already hardlinked into `/mnt/hdd/media` (>3 days old); prune subliminal cache; notify warning |
| `/mnt/hdd` ≥ 88% | crit | evict + pause Riven→JD2 bridge + JD2 + qBit; notify error |
| `/mnt/hdd` ≤ 75% | recover | resume bridge + JD2 + qBit; notify info |
| `/` ≥ 75% | warn | journalctl vacuum 200M, apt/nala clean, prune pnpm/npm/uv caches, prune `/tmp`, prune host + each running CT, vzdump prune (keep last 3) |
| `/` ≥ 85% | crit | same actions; notify error |

Tunables in `/etc/disk-watchdog/env` on Tiamat:
```
HDD_WARN=80
HDD_CRIT=88
HDD_RESUME=75
SSD_WARN=75
SSD_CRIT=85
HDD_EVICT_MIN_AGE_DAYS=3
HA_NOTIFY_WEBHOOK_URL=http://192.168.12.123:8123/api/webhook/disk-watchdog
```
The pause path stops the **upstream chokepoint** (`riven-jd2-bridge.service`) so no new RD links get pushed to JD2. JD2 finishes whatever is actively pulling and then idles via `myjdapi.downloadcontroller.pause(true)`. qBit is paused via its WebUI API. Resume reverses each step.
The eviction path is **hardlink-aware**: it only deletes files in `/mnt/hdd/torrents` whose link count is >1 (meaning the same inode also lives in `/mnt/hdd/media`). Removing the torrent-side name leaves the library file intact. Files with link count 1 (no library copy yet) are never touched.
## Files / paths
| Path | Purpose |
|---|---|
| `/opt/unified-guide/server.py` | aggregator + HTTP server |
| `/opt/unified-guide/static/{index.html,styles.css,app.js}` | grid UI |
| `/opt/yttv-scraper/yttv_scraper.py` | YT TV browse.json → M3U + XMLTV |
| `/etc/unified-guide/env` | `UG_*` config (mode 0600 — TMDB key + Jellyfin token) |
| `/etc/yttv-scraper/env` | `YTTV_*` config |
| `/var/lib/yttv-scraper/browse.json` | staged YouTube TV scrape input |
| `/var/cache/unified-guide/state.json` | aggregator output (HTTP server reads this) |
| `/data/streaming/unified.xml` | merged XMLTV (linear sources) — for Jellyfin |
| `/data/streaming/yttv/yttv.m3u` | YouTube TV M3U (Threadfin can ingest) |
| `/data/streaming/yttv/yttv-epg.xml` | YouTube TV XMLTV |
| `/data/streaming/yttv/yttv-channels.json` | name → videoId map (used for launch URLs) |
| `/var/lib/disk-watchdog/status.json` | watchdog state (poll-able by Pulse / Uptime Kuma) |
| `/var/lib/disk-watchdog/notifications.log` | rolling notifications |
## Notes
- All services (Jellyfin, HDHomeRun, IPTV via tvpass.org) run natively in CT-300. `UG_JELLYFIN_URL` and `UG_THREADFIN_URL` must use the **LAN IP** (`192.168.12.30`), not `127.0.0.1` — those services bind to the external interface, not loopback.
- IPTV EPG is sourced directly from `https://tvpass.org/epg.xml` via `UG_THREADFIN_XMLTV`. The refresher downloads and caches it to `/var/cache/unified-guide/threadfin.xml` each run. There is no Threadfin proxy in the path.
- Jellyfin API token lives in `/etc/jellyfin-autoscan.env` as `JELLYFIN_API_KEY`. The install script reads this field; re-run the script if the token ever rotates.
## Troubleshooting
| Symptom | Diagnosis | Fix |
||---|---|---|
|| Grid loads but lanes are empty | `state.json` not yet written | `pct exec 300 -- systemctl start unified-guide-refresh.service` |
|| SVOD lanes empty | TMDB key missing | `pct exec 300 -- grep UG_TMDB_API_KEY /etc/unified-guide/env`; populate, then restart `unified-guide.service` |
|| Library lane empty | Jellyfin token missing or wrong | check `UG_JELLYFIN_TOKEN` in `/etc/unified-guide/env`; must match `JELLYFIN_API_KEY` in `/etc/jellyfin-autoscan.env` |
|| IPTV lanes empty | `UG_THREADFIN_XMLTV` not set or tvpass.org unreachable | verify `/etc/unified-guide/env` has `UG_THREADFIN_XMLTV=https://tvpass.org/epg.xml`; check `journalctl -u unified-guide-refresh.service` for download errors |
|| YT TV lanes empty | `browse.json` missing/stale | re-stage per cookie procedure above |
|| Jellyfin/IPTV lanes empty, `Connection refused` in logs | Services bound to LAN IP, not loopback | ensure `UG_JELLYFIN_URL=http://192.168.12.30:8096` and `UG_THREADFIN_URL=http://192.168.12.30:34400` in env |
|| Click on OTA cell falls back to generic Live TV URL | XMLTV channel name doesn't match Jellyfin Live TV channel name | rename either side; aggregator matches `lower().strip()` |
|| Caddy says cert error | Internal CA not trusted on client | add `192.168.12.30 guide.mediastack.lan` to `/etc/hosts` and accept the Caddy internal cert (one-time per device) |
|| Watchdog paused downloads but didn't resume | `/mnt/hdd` still above `HDD_RESUME` | check `df /mnt/hdd`; lower threshold or free space; flag at `/var/lib/disk-watchdog/downloads.paused` |
|| `disk-space-watchdog` doesn't restart riven-jd2-bridge | service not present on host | `systemctl list-units 'riven*'` — bridge must be installed via `scripts/install-jd2-pipeline.sh` |
|| `myjdapi not installed` in watchdog log | python myjdapi missing on host | `pip install --break-system-packages myjdapi` or install the bridge first (which installs it) |
