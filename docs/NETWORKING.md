# Networking

## LAN Layout
```
T-Mobile Gateway (CGNAT — no bridge mode, locked DNS, no port forwarding)
  └── Archer AX55 Pro (192.168.12.1) — Router mode, DHCP server, DNS → AdGuard
        ├── Tiamat (Proxmox VE)       → 192.168.12.242 (static)
        ├── Bahamut (Raspberry Pi 4)  → 192.168.12.244 (static, DietPi edge node)
        ├── Laptop                    → 192.168.12.172 (DHCP reservation, may appear as .204)
        ├── Fire TV ×2                → DHCP
        └── Phones ×2                → DHCP
```

> **Why Router mode (not AP mode):** T-Mobile gateway has locked DNS (cannot point to AdGuard)
> and no DHCP reservation support. The Archer must control DHCP/DNS for the entire LAN.
> Double NAT is harmless — Tailscale handles remote access and CGNAT blocks inbound regardless.

DHCP reservations are managed at: `http://192.168.12.1` (Archer AX55 Pro admin)
DHCP DNS pushed to all clients: Primary `192.168.12.244` (AdGuard), Secondary `1.1.1.1`

> "Ziggy" is now CT-900 on Tiamat (Open WebUI + SearXNG). The name no
> longer refers to a Raspberry Pi.

## Proxmox Bridge
Proxmox host networking is bridged through `vmbr0` so all CTs/VMs get LAN access.

`/etc/network/interfaces`:
```
auto lo
iface lo inet loopback

auto enp3s0
iface enp3s0 inet manual

auto vmbr0
iface vmbr0 inet static
    address 192.168.12.242/24
    gateway 192.168.12.1
    bridge-ports enp3s0
    bridge-stp off
    bridge-fd 0
    dns-nameservers 192.168.12.1
```

## Core Service Map

> **Consolidated 2026-05-22**: All Proxmox LXC services merged into CT-300.
> **2026-05-28**: CT-501 `habridge` added for Alexa/Hue voice control.

### Proxmox host
| Service | URL |
|---|---|
| Proxmox UI | `https://192.168.12.242:8006` |

### HABridge — Alexa voice bridge (CT-300, port 80)
| Service | Port | URL |
|---|---|---|
| HABridge web UI + Hue API | 80 | `http://192.168.12.251` / `habridge.tiamat.local` |
| UPnP/SSDP discovery | 1900/udp | (Alexa auto-discovers on LAN) |

### CT-300 `mediastack` (192.168.12.30)
All services run inside this single privileged Debian 12 LXC.

| Service | Internal port | URL / hostname |
|---|---|---|
| Riven frontend | 3000 | `http://192.168.12.30:3000` / `riven.mediastack.lan` |
| Riven backend | 8080 | `http://192.168.12.30:8080` |
| Jellyfin | 8096 | `http://192.168.12.30:8096` / `jellyfin.mediastack.lan` / `jellyfin.tiamat.local` |
| n8n | 5678 | `http://192.168.12.30:5678` / `n8n.tiamat.local` |
| Threadfin (IPTV proxy) | 34400 | `http://192.168.12.30:34400/web` / `threadfin.tiamat.local` |
| Uptime Kuma | 3001 | `http://192.168.12.30:3001` / `uptime.tiamat.local` |
| Homarr (dashboard) | 7575 | `http://192.168.12.30:7575` / `homarr.mediastack.lan` · board: `/boards/Tiamat-Mediastack` · login: `admin` / `Mediastack2024!` |
| Pulse (Proxmox monitor) | — | web UI port in `/etc/pulse/.env` |
| Caddy (reverse proxy) | 80/443 | handles all `*.tiamat.local` + `*.mediastack.lan` routes |
| PostgreSQL 15 | 5432 | internal only (`riven` database) |
| Redis | 6379 | internal only |
| CrowdSec | 8081 | internal only |
| Tailscale | — | node `tiamat-tailscale` · `100.115.82.71` · funnel `https://tiamat-tailscale.tail9d8b73.ts.net` |

**Decommissioned CTs (2026-05-22):** CT-102 (n8n-stable), CT-103 (Traefik), CT-104 (Vaultwarden), CT-105 (Valkey), CT-106 (Postgres), CT-107 (Authentik), CT-110 (Pulse), CT-200 (HA DuckDNS proxy), CT-234 (Threadfin), CT-248 (Uptime Kuma), CT-279 (Tailscale)
**Running CTs (2026-05-28):** CT-300 `mediastack` (192.168.12.30), CT-501 `habridge` (192.168.12.251)
Vaultwarden backup: `/var/backup/mediastack/vaultwarden_pg_dump.sql` + `vaultwarden_data.tgz` in CT-300.

### VMs (unchanged)
| VM | Purpose | IP | Notes |
|---|---|---|---|
| VM-901 `windows-gaming` | Windows 11 gaming | `192.168.12.201` | RX 580 GPU passthrough |
| VM-990 `haos17-1` | Home Assistant OS | `192.168.12.123` | Smart home hub — ✅ static IP set via `ha network update enp6s18 --ipv4-method static` (permanent, no DHCP needed) |

### Laptop NFS Exports (192.168.12.172)
| Export path | Tiamat mount | Consumer |
|---|---|---|
| `/media/loufogle/Data/Calibre Library` | `/mnt/laptop/calibre` | CT-233 Calibre-Web |
| `/media/loufogle/Data/Cookbooks` | `/mnt/laptop/cookbooks` | CT-233 second library |
| `/media/loufogle/SystemBackup/Videos` | `/mnt/laptop/videos` | Plex / Jellyfin Home Videos |
| `/media/loufogle/ISOs1` | `/mnt/laptop/isos` | Proxmox ISO uploads |
| `/media/loufogle/Games/roms` | `/mnt/laptop/roms` | Future emulation frontend |
| `/media/loufogle/Data/Downloads/lou.m3u` | `/mnt/laptop/iptv/lou.m3u` | Jellyfin Live TV / TVHeadend CT-235 |

See `docs/NFS.md` for setup.

## VPN Architecture (kill-switch path)

CT-101 is not Gluetun software. It runs:
- `wireguard-tools` client to CT-100
- `tinyproxy` on port `8888`

Traffic flow:
```
qBittorrent/Prowlarr -> 192.168.12.101:8888 (TinyProxy)
                     -> WireGuard tunnel (CT-101 -> CT-100)
                     -> NAT on CT-100
                     -> Internet
```

If WG tunnel drops, proxy path breaks and downloads fail closed.

## Caddy Reverse Proxy (CT-300)
All `*.tiamat.local` and `*.mediastack.lan` hostnames are served by Caddy **inside CT-300** at `192.168.12.30:80/443`.
DNS wildcard: `*.tiamat.local → 192.168.12.30` via AdGuard rewrite on Bahamut.
Config: `infrastructure/caddy/Caddyfile` (also live at `/etc/caddy/Caddyfile` in CT-300).

| Hostname | Service | Backend |
|---|---|---|
| `riven.mediastack.lan`, `riven.local` | Riven UI | `127.0.0.1:3000` |
| `jellyfin.mediastack.lan`, `jellyfin.local` | Jellyfin | `127.0.0.1:8096` |
| `n8n.tiamat.local` | n8n | `127.0.0.1:5678` |
| `uptime.tiamat.local`, `uptimekuma.tiamat.local` | Uptime Kuma | `127.0.0.1:3001` |
| `threadfin.tiamat.local` | Threadfin | `192.168.12.30:34400` |
| ha.tiamat.local, homeassistant.tiamat.local | Home Assistant VM-990 | `192.168.12.123:8123` |
| habridge.tiamat.local | HABridge CT-501 | `192.168.12.251:80` |
| `sonarr.tiamat.local` | Sonarr (stopped CT-214) | `192.168.12.214:8989` |
| `radarr.tiamat.local` | Radarr (stopped CT-215) | `192.168.12.225:7878` |
| `prowlarr.tiamat.local` | Prowlarr (stopped CT-210) | `192.168.12.210:9696` |
| `homarr.mediastack.lan`, `homarr.local` | Homarr dashboard | `127.0.0.1:7575` |
| `guide.mediastack.lan`, `guide.local` | Guide / Meilisearch | `127.0.0.1:7700` |
| `cockpit.mediastack.lan` | Cockpit | `127.0.0.1:9090` |

To add a route, append a block to `/etc/caddy/Caddyfile` in CT-300 and `systemctl reload caddy`.
Also sync to `infrastructure/caddy/Caddyfile` in this repo.

**CT-103 Traefik decommissioned 2026-05-22.** Old Traefik configs preserved in `infrastructure/traefik/dynamic/` for reference.

## DNS / Remote Access on Bahamut

Bahamut (`192.168.12.244`, Raspberry Pi 4, DietPi) runs:
- AdGuard Home (primary DNS, Docker): `:53`, admin UI `:3000` (external `:8081`)
  - Rewrite: `*.tiamat.local → 192.168.12.30` (CT-300)
- wg-easy (WireGuard remote VPN): `http://192.168.12.244:51821`
- WireGuard tunnel endpoint: `:51820/udp`
- Vaultwarden (native): `https://192.168.12.244` (TLS via DuckDNS caddy)
- Caddy (Docker): handles `*.lou-fogle-media-stack.duckdns.org` TLS
  - `vaultwarden.*` → `localhost:8080`
  - `ha.*` → `192.168.12.123:8123` (Home Assistant VM-990)
|- `wg.*` → `localhost:51821`
|- `adguard.*` → `localhost:8081`

> **AdGuard DNS rewrites required for voice control:**
> Add `habridge.tiamat.local → 192.168.12.30` (CT-300 Caddy) and
> `ha.tiamat.local → 192.168.12.30` alongside the existing `*.tiamat.local` wildcard.
- DietPi Dashboard: `:5252`
- TigerVNC: `:5901`

> **Tailscale removed from Bahamut (2026-05-22).** Tailscale now runs inside CT-300 as `tiamat-tailscale` (100.115.82.71).

Router DNS recommendation:
1. `192.168.12.244`
2. `1.1.1.1`
