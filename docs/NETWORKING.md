# Networking

## LAN Layout
```
Router (192.168.12.1)
├── Tiamat (Proxmox VE)       → 192.168.12.242 (static)
├── Bahamut (Raspberry Pi 4)  → 192.168.12.244 (static, DietPi edge node)
├── Laptop                    → 192.168.12.172 (DHCP reservation, may appear as .204 — verify with `ip addr show enp4s0`)
├── Fire TV                   → DHCP
└── Tablet / phones           → DHCP
```

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

### Proxmox host
| Service | URL |
|---|---|
| Proxmox UI | `https://192.168.12.242:8006` |

### Infrastructure CTs
| CT | Purpose | URL / Port |
|---|---|---|
| CT-100 `wireguard` | WireGuard server | `:51820/udp` |
| CT-101 `wg-proxy` | WireGuard client + TinyProxy | `http://192.168.12.101:8888` |
| CT-102 `n8n` | Workflow automation / AI bridge | `http://192.168.12.102:5678` |
| CT-103 `traefik` | Reverse proxy | `:80`, `:443`, `:8080` |
| CT-104 `vaultwarden` | Password manager backend | `https://192.168.12.104` (Caddy TLS) |
| CT-105 `valkey` | Redis-compatible cache | `:6379` |
| CT-106 `postgresql` | Database | `:5432` |
| CT-107 `authentik` | SSO | `http://192.168.12.107:9000` |
| CT-108 `flaresolverr` | Cloudflare bypass | `http://192.168.12.108:8191` |
| CT-109 `byparr` | FlareSolverr alternative (stopped/standby) | `http://192.168.12.109:8191` |
| CT-112 `byparr` | FlareSolverr alternative (active) | `http://192.168.12.109:8191` |

### Download stack
| Service | URL | Status |
|---|---|---|
| Prowlarr (CT-210) | `http://192.168.12.210:9696` | running |
| Jackett (CT-211) | `http://192.168.12.211:9117` — fallback indexer (hdd-ct) | stopped |
| qBittorrent (CT-212) | `http://192.168.12.212:8080` | running |
| rdtclient (CT-213) | `http://192.168.12.213` — Real-Debrid client (replaces Deluge-fallback) | running |
| Sonarr (CT-214) | `http://192.168.12.214:8989` | running |
| Radarr (CT-215) | `http://192.168.12.225:7878` | running |
| Decluttarr (CT-216) | `http://192.168.12.216` — queue cleaner for *arr | running |
| Readarr (CT-217) | `http://192.168.12.217:8787` | stopped |
| Recyclarr (CT-245) | `http://192.168.12.245` — quality profile sync | running |

> CT-219 (Whisparr), CT-220 (Sonarr Extended), CT-223 (Autobrr), CT-224 (Deluge) — decommissioned.

### Riven mediastack
| Service | URL | Notes |
|---|---|---|
| CT-300 `mediastack` | `http://192.168.12.30:3000` (Riven UI) / `:8080` (backend) / `:8096` (Jellyfin) | Privileged Debian 12 LXC — Riven + RivenVFS + Jellyfin + Postgres + Redis |

> This replaced the *arr+torrent stack for primary streaming. See `README.md` for architecture.

### Media servers
| Service | URL | Status |
|---|---|---|
| Plex (CT-230) | `http://192.168.12.230:32400/web` | stopped |
| Jellyfin (CT-231) | `http://192.168.12.231:8096` | running |

### VMs
| VM | Purpose | IP | Notes |
|---|---|---|---|
| VM-901 `windows-gaming` | Windows 11 gaming | `192.168.12.201` | RX 580 GPU passthrough, sdb disk passthrough |
| VM-990 `haos17-1` | Home Assistant OS | DHCP (`.250` static reservation) | Smart home hub — was VM-500 |

### AI CTs
| CT | Purpose | URL |
|---|---|---|
| CT-102 `n8n` | Workflow automation — Self-Healing Code Assistant webhook → Ollama | `http://192.168.12.102:5678` |
| CT-900 `ziggy` | Open WebUI + SearXNG (stopped/standby) | `http://192.168.12.250:3000` |

> CT-102 was recreated 2026-05-19; Ollama URL in n8n workflow must match current laptop IP (see Laptop note above).

> CT-200 `alexa-media-bridge` is an LXC at `192.168.12.200`, not a VM.

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

## Traefik Reverse Proxy Routes (CT-103)
All services are accessible via `*.tiamat.local` through Traefik at `192.168.12.103`.
Dynamic route files live in `infrastructure/traefik/dynamic/`.

| Hostname | Service | Backend |
|---|---|---|
| `traefik.tiamat.local` | Traefik dashboard | `192.168.12.103:8080` |
| `jellyfin.tiamat.local` | Jellyfin (CT-231) | `192.168.12.231:8096` |
| `plex.tiamat.local` | Plex (CT-230) | `192.168.12.230:32400` |
| `sonarr.tiamat.local` | Sonarr (CT-214) | `192.168.12.214:8989` |
| `radarr.tiamat.local` | Radarr (CT-215) | `192.168.12.225:7878` |
| `prowlarr.tiamat.local` | Prowlarr (CT-210) | `192.168.12.210:9696` |
| `qbittorrent.tiamat.local` | qBittorrent (CT-212) | `192.168.12.212:8080` |
| `jackett.tiamat.local` | Jackett (CT-211) | `192.168.12.211:9117` |
| `deluge.tiamat.local` | Deluge fallback (CT-213) | `192.168.12.213:8112` |
| `bazarr.tiamat.local` | Bazarr (CT-240) | `192.168.12.188:6767` \* |
| `jellyseerr.tiamat.local` | Seerr/Jellyseerr (CT-242) | `192.168.12.151:5055` \* |
| `vault.tiamat.local` | Vaultwarden (CT-104) | `https://192.168.12.104:443` (via serversTransport skip-verify) |
| `vaultwarden.tiamat.local` | Vaultwarden (CT-104) | `https://192.168.12.104:443` (alias) |
| `auth.tiamat.local` | Authentik (CT-107) | `192.168.12.107:9000` |
| `jellystat.tiamat.local` | Jellystat (CT-247) | `192.168.12.247:3000` |
| `uptime.tiamat.local` | Uptime Kuma (CT-248) | `192.168.12.248:3001` |
| `threadfin.tiamat.local` | Threadfin (CT-234) | `192.168.12.234:34400` |
| `dispatcharr.tiamat.local` | Dispatcharr (CT-235) | `192.168.12.235:9191` |
| `n8n.tiamat.local` | n8n (CT-102) | `192.168.12.102:5678` |

\* CT-242 has static IP 192.168.12.151. CT-240 is DHCP — set a static reservation on the router.
CT-242 runs Seerr natively (no Docker). Proxmox vmbr0 has static ARP for Radarr: `ip neigh replace 192.168.12.225 dev vmbr0 lladdr BC:24:11:2A:83:BB nud permanent`
then update `infrastructure/traefik/dynamic/media-management.yml` if IPs change.

To add a new route, drop a YAML file in `/etc/traefik/dynamic/` on CT-103.
Traefik hot-reloads it immediately (no restart needed).

## DNS / Remote Access on Bahamut

Bahamut (`192.168.12.244`, Raspberry Pi 4, DietPi) runs:
- AdGuard Home (primary DNS): `:53`, admin UI `:8081`
- wg-easy (remote VPN mgmt): `http://192.168.12.244:51821`
- WireGuard tunnel endpoint: `:51820/udp`
- Vaultwarden behind Caddy: `https://192.168.12.244` (TLS via DuckDNS)
- DietPi Dashboard: `:5252`
- TigerVNC: `:5901`
- Tailscale (mesh VPN)

Router DNS recommendation:
1. `192.168.12.244`
2. `1.1.1.1`
