# Homarr — Tiamat Control Center

Homarr v1 (homarr-labs) runs natively in **CT-300** at `http://192.168.12.30:7575`.
Board name: **Tiamat Mediastack** (public — no login required to view).
All services are consolidated in CT-300 at `192.168.12.30` unless noted.

## Access

- `http://192.168.12.30:7575`

## Board — Current Apps (16 total)

### Media Stack
| App | URL |
|-----|-----|
| Riven | http://192.168.12.30:3000 |
| Jellyfin | http://192.168.12.30:8096 |
| Threadfin | http://192.168.12.30:34400/web/ |
| Real-Debrid | https://real-debrid.com/ |
| Unified Guide | http://192.168.12.30:7700 |
| Sportarr | http://192.168.12.30:1867 |

### Automation
| App | URL |
|-----|-----|
| n8n | http://192.168.12.30:5678 |
| Uptime Kuma | http://192.168.12.30:3001 |
| Pulse | http://192.168.12.30:7655 |

### Infrastructure
| App | URL |
|-----|-----|
| Proxmox | https://192.168.12.242:8006 |
| AdGuard Home | http://192.168.12.244:8081 |
| Home Assistant | http://192.168.12.250:8123 |
| Homarr | http://192.168.12.30:7575 |
| Cockpit | http://192.168.12.30:9090 |

### Laptop (192.168.12.172)
| App | URL |
|-----|-----|
| Ollama WebUI | http://192.168.12.172:3535 |
| Immich | http://192.168.12.172:17486 |

## CT-300 Port Reference

All on `192.168.12.30`:

| Port | Service |
|------|---------|
| 80/443 | Caddy |
| 1867 | Sportarr |
| 3000 | Riven frontend |
| 3001 | Uptime Kuma |
| 7575 | Homarr |
| 7655 | Pulse |
| 7700 | Unified Guide |
| 8080 | Riven backend |
| 8096 | Jellyfin |
| 9090 | Cockpit |
| 34400 | Threadfin |

## Database

Homarr stores everything in `/opt/homarr_db/db.sqlite` (SQLite).
No user accounts — board is public.

Board ID: `cJzUFLVTV2pPIg` · Layout ID: `je9xPeIfxxxqsg`

Section IDs:
- `qrhRB5w6tFA1zg` — Media Stack
- `BBrHcP7f2BhD6A` — Automation
- `AS7cW8Ncy6Jxag` — Infrastructure
- `iMM370vFhVmx1w` — Laptop

## Install / redeploy

```
ssh tiamat 'cd ~/bulletproof-mediastack && git pull'
bash scripts/install-homarr-ct300.sh
```
