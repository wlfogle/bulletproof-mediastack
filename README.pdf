# bulletproof-mediastack
**Post-*arr media pipeline.** Forked from [`wlfogle/homelab-media-stack`](https://github.com/wlfogle/homelab-media-stack) after the *arr-stack approach failed across 11 deployment attempts. This repo is the clean restart.
## What this is
One privileged Proxmox LXC running four services that together turn a request in a web UI into a playable file in Jellyfin within ~30–60 seconds. No torrent downloads, no `/mnt/media` filling up, no SQLite WAL contention, no `*arr` config drift to babysit.
```text
   ┌─────────┐   ┌────────┐   ┌─────────┐   ┌──────────┐
   │ Riven   │ → │  zurg  │ → │ rclone  │ ← │ Jellyfin │
   │ UI/scrape   │ RD WebDAV │ /mnt/zurg│   │ (scans)  │
   └─────────┘   └────────┘   └─────────┘   └──────────┘
        ↑
  user request
```
## How it works
1. You search & add a show or movie in **Riven** (port 3000).
2. Riven scrapes for Real-Debrid-cached torrents and adds the magnet to your RD library via the RD API.
3. **zurg** polls RD and exposes your RD library as WebDAV (port 9999).
4. **rclone** mounts that WebDAV at `/mnt/zurg` as a normal filesystem — files appear instantly, served on demand from RD's CDN.
5. Riven creates a symlink under `/mnt/library/{movies,shows}` pointing into `/mnt/zurg`.
6. **Jellyfin**'s real-time monitor detects the new symlink and the file is playable.
Total time from "add" to "play": 30–60 seconds. Disk space used: 0 bytes (the file lives at Real-Debrid; rclone caches just the parts you're actively streaming, capped at 4 GB).
## What's gone vs. the *arr stack
- ❌ Sonarr, Radarr, Prowlarr, Bazarr, Jellyseerr — replaced by Riven
- ❌ qBittorrent, RDT-Client — Riven talks to RD directly
- ❌ FlareSolverr, Byparr, Jackett — RD already cached it
- ❌ recyclarr, decluttarr, Jellystat, Tautulli, Threadfin — not needed
- ❌ `/mnt/media` on disk — files live at RD, mounted via rclone
- ❌ Watchdogs auto-recreating Connect webhooks — Riven creates symlinks directly
- ❌ Per-CT API key drift, SQLite WAL contention, IO storms during backups
## Hardware target
Same as upstream:
- **Tiamat** — Proxmox host, AMD Ryzen 5 3600, 32 GB RAM, RX 580 (VAAPI), 1.8 TB HDD (mostly empty now — we're not storing media). See [`docs/HARDWARE.md`](docs/HARDWARE.md).
- **Bahamut** — Pi 4 (DNS / VPN / Vaultwarden) — untouched.
## Deploy
On the Proxmox host (Tiamat) as root:
```bash
git clone https://github.com/wlfogle/bulletproof-mediastack.git /opt/bulletproof-mediastack
cd /opt/bulletproof-mediastack
cp .env.example .env
# Edit .env: paste your Real-Debrid API token from https://real-debrid.com/apitoken
nano .env
bash scripts/deploy.sh
```
After ~5–10 minutes the script prints URLs for Riven, Jellyfin, and zurg. Open the Riven UI, finish first-run setup (it auto-detects the RD token), point Jellyfin at `/mnt/library/{movies,shows}`, and you're done.
## Requirements
- Proxmox VE host with `pct`
- A **Real-Debrid** subscription (or AllDebrid / Premiumize — the script defaults to RD; trivial to swap)
- One privileged LXC's worth of resources (~4 GB RAM, 4 cores, 16 GB rootfs)
- Internet, fast enough for streaming (any home connection ≥50 Mbps is fine; rclone caches the active stream)
## Why this works when *arr didn't
The *arr stack's failure mode on this hardware was always the same: a single 1.8 TB HDD trying to serve 14 LXC rootfs partitions, multiple SQLite WALs, qBit incomplete writes, and Jellyfin metadata scans **at the same time**. Every backup, every update, every stalled torrent caused IO storms that cascaded into "database is locked" errors across the *arr suite.
This stack moves the storage concern off the disk entirely (Real-Debrid is the storage now) and collapses 14 services into 4. The four remaining services don't compete: zurg + rclone read from RD, Riven manages metadata in PostgreSQL, Jellyfin reads symlinks. No service writes large blobs to local disk except rclone's small ephemeral cache. The IO storm cannot happen.
## Troubleshooting
```bash
# All services in CT-300:
pct exec 300 -- systemctl status zurg rclone-zurg riven riven-frontend jellyfin
# Live logs:
pct exec 300 -- journalctl -fu zurg
pct exec 300 -- journalctl -fu rclone-zurg
pct exec 300 -- journalctl -fu riven
# Verify rclone mount:
pct exec 300 -- ls /mnt/zurg
# Verify zurg is talking to Real-Debrid:
pct exec 300 -- curl -s http://127.0.0.1:9999/dav | head
```
## Reverting / running alongside the *arr stack
The deploy script creates **CT-300** at IP `192.168.12.30` by default — collision-free with the existing *arr CT IDs and IPs in the upstream repo. You can run both side by side, prove this works for a week, then `pct stop` the old containers (102, 109, 151/242, 210, 211, 212, 213, 214, 215/225, 240, 231) and `pct destroy` them when you're confident.
## Related
- Upstream history (the *arr-stack we're replacing): [`wlfogle/homelab-media-stack`](https://github.com/wlfogle/homelab-media-stack)
- Riven: https://github.com/rivenmedia/riven
- zurg-testing: https://github.com/debridmediamanager/zurg-testing
- rclone WebDAV: https://rclone.org/webdav/
- Jellyfin: https://jellyfin.org
