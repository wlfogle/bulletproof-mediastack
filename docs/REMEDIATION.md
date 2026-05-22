# Homelab Remediation — Critical Issues Across Laptop, Tiamat, Bahamut
*Inventory date: 2026-05-20*

---

## Breaking / Active Risk (fix immediately)

### 1a. Laptop primary NVMe 94% full — CRITICAL
- **857 GB / 907 GB used** on `/dev/nvme1n1p3` (root filesystem) — only **4.6 GB free**
- Root cause (measured):
  - `.steam` — **322 GB** (Steam games library — dominant consumer)
  - `.local` — 76 GB (Flatpak runtimes + app data)
  - `.wine` — 62 GB (Wine prefix + Windows apps)
  - `.var` — 61 GB (Flatpak app state)
  - Android SDK + emulators — ~41 GB
  - Docker images/containers — ~58 GB (54 GB images, 30 GB reclaimable; data root is non-standard, not at `/var/lib/docker`)
  - Downloads, caches, build tools — ~25 GB
- Ollama models are **NOT on this drive** — they are on the separate model drive (see 1b)
- Fix:
  - Move Steam library to the model drive or external storage
  - `docker image prune -a` to reclaim 29.85 GB of unused images
  - `docker builder prune -af` to reclaim 1.2 GB build cache
  - `journalctl --vacuum-size=200M`
  - Clean `.cache` (8.1 GB): `rm -rf ~/.cache/thumbnails ~/.cache/pip ~/.cache/ms-playwright`
  - Target: below 80% (free up ~130 GB minimum)

### 1b. Laptop Ollama model drive 89% full — HIGH
- **282 GB / 337 GB used** on `/dev/nvme0n1p2` — only **38 GB free**
- Ollama models stored at `/media/loufogle/73cf9511-0af0-4ac4-9d83-ee21eb17ff5d/models/` (280 GB)
- Largest models (candidates for removal if not actively used):
  - `llama3.2-vision:90b` — **54 GB**
  - `llama3.3:70b` — **42 GB**
  - `mixtral:8x7b` — 26 GB
  - `wizard-vicuna-uncensored:30b` — 18 GB
  - `phi4:latest` — 9.1 GB, `llava:13b` — 8.0 GB, `llama3.2-vision:11b` — 7.8 GB
- Fix: `ollama rm llama3.2-vision:90b llama3.3:70b` frees **96 GB** instantly; review others

### 2. Laptop swap 92% full — CRITICAL
- **18.9 GB / 20.5 GB used**
- Root cause: 30+ Docker containers + systemd Ollama + Steam/Wine processes exhausting 64 GB RAM
- Risk: OOM kill of Ollama, Docker daemon, or VS Code at any moment
- Fix: correlated with disk fix 1a above; reclaiming Docker images releases RSS pressure; removing unused large Ollama models stops VRAM/RAM contention

### 3. Gluetun VPN UNHEALTHY on laptop — CRITICAL
- `gluetun` container status: `Up 46 hours (unhealthy)`
- `qbittorrent` container routes all traffic through gluetun; if tunnel is broken the real IP leaks on every torrent connection **right now**
- Fix: `docker logs gluetun --tail 100` to identify failure mode (auth error, dead endpoint, missing env); restart after fixing; verify with `docker exec gluetun curl https://ifconfig.me`

### 4. ~~CT-110 and CT-111 share identical MAC + IP~~ — RESOLVED 2026-05-20
- Both assigned `hwaddr=BC:24:11:E0:78:C6` and `ip=192.168.12.251/24`
- Both were "pulse" (Proxmox monitoring community script) and both were `onboot: 1`
- CT-111 **destroyed** — CT-110 remains running as the sole pulse instance
- ARP conflict eliminated

### 5. ~~qBittorrent CT-212 not responding~~ — RESOLVED 2026-05-20
- CT-212 **destroyed** — config no longer exists on Tiamat
- No data to migrate: Real-Debrid has replaced torrenting
- Traefik route `qbittorrent.tiamat.local` is now stale (cleanup in Phase 3)

---

## Architecture / Data Integrity Issues (high priority)

### 6. Full *arr stack duplicated across laptop Docker and Tiamat LXCs
The laptop runs a complete parallel media stack via Docker Compose. The following services have live instances in **both** places with separate databases:

| Service | Laptop (Docker) | Tiamat (LXC) |
|---|---|---|
| Sonarr | :8989 (running) | CT-214 :8989 (running) |
| Radarr | :7878 (running) | CT-215 :7878 (running) |
| Prowlarr | :9696 (running) | CT-210 :9696 (running) |
| Jackett | :9117 (running) | CT-211 (stopped) |
| Readarr | :8787 (running) | CT-217 (stopped) |
| Lidarr | :8686 (running) | not in Tiamat |
| Bazarr | :6767 (running) | CT-240 (DHCP) |
| Jellyfin | (running) | CT-231 (running) |
| Jellyseerr | :5055 (running) | CT-242 :5055 (running) |
| Plex | (running) | CT-230 (stopped) |
| qBittorrent | :8080 via gluetun | CT-212 (broken) |

**Decision required:** pick one stack as authoritative per service and decommission the other.
Recommendation: Tiamat LXCs are the intended authoritative home. Laptop Docker services should be stopped and their config/DB backed up to Tiamat.

Additional laptop-only services not duplicated (no Tiamat equivalent):
- `immich` (photo library) + postgres + redis — :17486
- `homeassistant` — (port not exposed; likely :8123)
- `audiobookshelf` — :13378
- `autobrr` — :7474
- `doplarr`, `flexget`, `htpcmanager` — various ports
- `mediastack-control` — :9900
- `ollama-gpt` — :3535
- `wg-easy` — healthy (see §8 below)
- `vaultwarden` — :4444 (see §7 below)

### 7. Vaultwarden in three half-deployed states
| Location | Status | Port |
|---|---|---|
| CT-104 on Tiamat | running | HTTPS :443 via Caddy |
| Laptop Docker | running | :4444 |
| Bahamut containerd | stopped snapshot only | — |

User preference: Vaultwarden should live on **Bahamut**.
Action: migrate the authoritative data to Bahamut, then stop both other instances.
Data consolidation must happen before decommissioning either running instance.

### 8. wg-easy lives on laptop, not Bahamut
- `wg-easy` Docker container is healthy on the laptop
- Bahamut has no `wg-easy` systemd service and no running Docker container for it
- `docs/NETWORKING.md` incorrectly lists `wg-easy` at `http://192.168.12.244:51821`
- Decision: migrate to Bahamut as intended, or update docs to reflect laptop as the permanent home

### 9. ~~Dispatcharr CT-235 not responding~~ — RESOLVED 2026-05-20
- CT-235 **destroyed** — config no longer exists on Tiamat
- No data to migrate
- Traefik route `dispatcharr.tiamat.local` is now stale (cleanup in Phase 3)

### 10. Laptop IP .204, docs say .172
- `ip addr show enp4s0` shows `192.168.12.204`
- `docs/AI.md` and `docs/NETWORKING.md` say `.172` (static DHCP reservation)
- n8n in CT-102 has `OLLAMA_HOST` pointing to wrong IP
- Fix: verify current DHCP lease, set static reservation to `.204` in router, update docs

---

## Dead / Stale Resources (medium priority, cleanup)

### 11. CT-275 (homarr) — stopped, DHCP, dead weight
- Homarr service migrated into CT-300 (nginx on :7575, responding 307)
- CT-275 has no static IP and is permanently stopped
- Fix: `pct stop 275 2>/dev/null; pct destroy 275` — frees disk on local-lvm

### 12. CT-900 (Open WebUI / Ziggy) — deleted, still in docs
- Not present in `pct list` — the CT was destroyed
- `docs/NETWORKING.md` and `docs/AI.md` still reference it
- Fix: remove from all docs in same commit as other doc updates

### 13. VM-901 (Windows gaming) — deleted, still in docs
- Not present in `qm list` — VM was destroyed
- `docs/NETWORKING.md` still lists it
- Fix: remove from docs

### 14. Tiamat `local` pool 75% full
- `local` (PVE root dir): 74 GB / 94 GB — approaching Proxmox 80% warning threshold
- Fix: `pve-manager` will warn at 80%; prune old CT backups, destroy CT-275 disk, clean APT cache on host

### 15. Bahamut memory critically low (idle)
- 117 MB free / 1.8 GB at idle with only AdGuardHome + DietPi + tailscaled running
- Will OOM if Vaultwarden is added without first removing something else or upgrading RAM
- Fix: if Vaultwarden migrates here, stop Xtigervnc (:5901) and DietPi dashboard (:5253) to recover ~100 MB

### 16. CT-245 recyclarr IP (.245) collides with Bahamut wlan0 (.245)
- CT-245 has static IP `192.168.12.245`
- Bahamut `wlan0` has IP `192.168.12.245` (currently DOWN)
- If Bahamut wlan0 ever comes up, routing breaks for recyclarr
- Fix: reassign CT-245 to unused IP, or ensure Bahamut wlan0 stays permanently down

---

## Documentation Gaps (update NETWORKING.md in one commit)

| Item | Current docs | Reality |
|---|---|---|
| Laptop IP | 192.168.12.172 | 192.168.12.204 |
| wg-easy location | Bahamut :51821 | Laptop Docker (healthy) |
| Vaultwarden | CT-104 Tiamat | CT-104 + laptop Docker + dead Bahamut snapshot |
| Homarr | CT-275 :7575 | CT-300 :7575 (nginx) — CT-275 dead |
| CT-900 ziggy | stopped/standby | deleted |
| VM-901 windows-gaming | stopped | deleted |
| CT-300 services | Riven + Jellyfin only | +apache2, mariadb, metatube, sportarr, riven-jd2-bridge, unified-guide, homarr, x11vnc/xvfb |
| CT-300 Homarr URL | not listed | `http://192.168.12.30:7575` |

---

## Remediation Sequence

```
Phase 1 — Stop active damage ✅ COMPLETED 2026-05-20
  1. Fix gluetun → stop IP leak                              (pending — laptop task)
  2. Stop CT-111 → resolve ARP conflict                      ✅ destroyed
  3. Free primary NVMe → prune Docker images etc.            (pending — laptop task)
  4. Free Ollama drive → remove large models                 (pending — laptop task)
  5. qBittorrent CT-212 → destroyed (Real-Debrid replaced)   ✅
  6. Dispatcharr CT-235 → destroyed                          ✅
  CT-300 consolidation prep:
  7. Rootfs expanded to 64 GB                                ✅
  8. RAM confirmed at 12 GB                                  ✅

Phase 2 — n8n + workflow migration ✅ COMPLETED 2026-05-22
  - n8n migrated CT-102 → CT-300, workflows fixed, webhooks active
  - 7 automation workflows added (Health Watchdog, Rootfs Guard, Riven Failure Handler,
    Library Digest, RD Expiry Alert, Maintenance Bundle, CrowdSec Digest)
  - n8n-local-api sidecar (127.0.0.1:9876) for system operations

Phase 3 — Traefik → Caddy ✅ COMPLETED 2026-05-22
  - All *.tiamat.local routes migrated to CT-300 Caddy
  - AdGuard wildcard *.tiamat.local → 192.168.12.30 added
  - CT-103 (Traefik) destroyed
  - Caddyfile live in infrastructure/caddy/Caddyfile

Phase 4 — CT consolidation ✅ COMPLETED 2026-05-22
  Destroyed: CT-102, CT-103, CT-104, CT-105, CT-106, CT-107,
             CT-110, CT-200, CT-234, CT-248, CT-279
  Migrated into CT-300:
    - Threadfin   → /opt/threadfin, port 34400
    - Uptime Kuma → /opt/uptime-kuma, port 3001
    - Tailscale   → node tiamat-tailscale, 100.115.82.71 (subnet routing disabled)
    - Pulse       → /opt/pulse, port 7655/9091, Ollama URL fixed to laptop
  Vaultwarden backup: /var/backup/mediastack/ in CT-300
  HA DuckDNS proxy moved to Bahamut Caddy

Phase 5 — Docs finalization ✅ COMPLETED 2026-05-22
  - NETWORKING.md fully rewritten for final architecture
  - AI.md updated with all 10 active n8n workflows
  - infrastructure/caddy/Caddyfile added to repo

Verification (2026-05-22 — all from laptop)
  ✅ ping 192.168.12.30 — 0% loss
  ✅ Riven UI     :3000  HTTP 307
  ✅ Riven backend:8080  HTTP 401 (auth required)
  ✅ Jellyfin     :8096  HTTP 200
  ✅ n8n          :5678  HTTP 200
  ✅ Threadfin    :34400 HTTP 200
  ✅ Uptime Kuma  :3001  HTTP 426 (WebSocket / normal)
  ✅ Homarr       :7575  HTTP 307
  ✅ Pulse        :7655  HTTP 200
  ✅ Caddy HTTPS  n8n.tiamat.local         200
  ✅ Caddy HTTPS  uptime.tiamat.local      426
  ✅ Caddy HTTPS  jellyfin.mediastack.lan  302
  ✅ Caddy HTTPS  riven.mediastack.lan     307
  ✅ Tailscale    tiamat-tailscale 100.115.82.71 connected
  ✅ DNS          *.tiamat.local → 192.168.12.30 via AdGuard
  ✅ n8n webhooks fix-code, jellyfin-refresh, media-ingested active

Still pending (laptop tasks)
  - Fix gluetun VPN or remove (Real-Debrid makes torrenting obsolete)
  - Stop laptop Docker duplicates (Sonarr, Radarr, Prowlarr containers)
  - Free laptop primary NVMe (94% full — prune Docker/Steam)
  - Free Ollama model drive (89% — remove unused 90b/70b models)
  12. Remove stale Traefik routes: qbittorrent.tiamat.local, dispatcharr.tiamat.local
```

---

## Service Reachability Reference (as of 2026-05-20)

| Service | URL | Status |
|---|---|---|
| Jellyfin CT-231 | http://192.168.12.231:8096 | ✅ 302 |
| Jellyseerr CT-242 | http://192.168.12.151:5055 | ✅ 307 |
| Sonarr CT-214 | http://192.168.12.214:8989 | ✅ 302 |
| Radarr CT-215 | http://192.168.12.225:7878 | ✅ 302 |
| Prowlarr CT-210 | http://192.168.12.210:9696 | ✅ 302 |
| n8n CT-300 | http://192.168.12.30:5678 | ✅ 200 — synchronized from CT-102 on 2026-05-22 |
| Traefik CT-103 | http://192.168.12.103:8080 | ✅ 301 |
| Authentik CT-107 | http://192.168.12.107:9000 | ✅ 302 |
| Uptime Kuma CT-248 | http://192.168.12.248:3001 | ✅ 302 |
| Threadfin CT-234 | http://192.168.12.234:34400 | ✅ 200 |
| Riven UI CT-300 | http://192.168.12.30:3000 | ✅ 307 |
| Jellyfin CT-300 | http://192.168.12.30:8096 | ✅ 302 |
| Homarr CT-300 | http://192.168.12.30:7575 | ✅ 307 |
| qBittorrent CT-212 | http://192.168.12.212:8080 | 🗑️ destroyed 2026-05-20 |
| Dispatcharr CT-235 | http://192.168.12.235:9191 | 🗑️ destroyed 2026-05-20 |
| Riven backend CT-300 | http://192.168.12.30:8080 | ⚠️ 404 |
| AdGuard Bahamut | http://192.168.12.244:8081 | ✅ (port listening) |
