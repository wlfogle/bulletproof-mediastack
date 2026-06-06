# Networking

## LAN Layout
```
T-Mobile KVD21 Gateway (192.168.12.1) — DHCP server, CGNAT, locked DNS, no settings
  └── Archer AX55 Pro (192.168.12.234) — AP mode (WiFi + switch only, no routing)
        ├── Tiamat (Proxmox VE)       → 192.168.12.242 (static)
        ├── Bahamut (Raspberry Pi 4)  → 192.168.12.244 (static, DietPi edge node)
        ├── Laptop                    → 192.168.12.172 (WiFi) / .204 (Ethernet)
        ├── Fire TV ×2                → DHCP
        └── Phones ×2                → DHCP
```

> **Why AP mode (not Router mode):** The T-Mobile KVD21 gateway blocks internet forwarding
> when a second router does NAT behind it — even the Archer itself cannot ping 1.1.1.1 in
> Router mode. The KVD21 admin UI has no configurable settings (DNS, DHCP, port forwarding
> are all locked). AP mode is the only viable configuration.

Archer AP admin: `http://192.168.12.234` (static IP set in AP mode LAN settings)
KVD21 admin: `http://192.168.12.1` (read-only status only — no configurable settings)

> **DNS note:** KVD21's DHCP pushes its own DNS (not AdGuard). Set AdGuard DNS manually
> per-device per `docs/ADGUARD-DEVICE-SETUP.md`. Critical infrastructure (Tiamat, Bahamut,
> CTs, Home Assistant) already has static DNS pointing to `192.168.12.244`.

> "Ziggy" is now CT-900 on Tiamat (Open WebUI + SearXNG). The name no
> longer refers to a Raspberry Pi.

## OpenWrt VM Router
VM-100 `openwrt` is deployed on Tiamat as the future routing/DHCP/DNS control plane.

Current state:
- VMID: `100`
- Storage: `local-ssd`
- WAN NIC: `eth0` on `vmbr0`, DHCP from KVD21/Archer LAN (`192.168.12.x`; currently observed as `192.168.12.145`)
- LAN NIC: `eth1` on `vmbr1`, static `10.10.0.1/24`
- LuCI: `http://10.10.0.1/` from Tiamat or any host attached to `vmbr1`
- SSH: `ssh root@10.10.0.1` from Tiamat
- Root password: stored on Tiamat at `/root/openwrt-root-password` with mode `0600`
- Package manager: `apk` on OpenWrt 25.12.2, not `opkg`
- Proxmox guest agent: enabled and verified with `qm agent 100 ping`

Important limitation: because `vmbr1` is virtual-only, OpenWrt currently serves only virtual clients attached to `vmbr1`. It does not serve phones, Fire TVs, or laptop WiFi yet. Full physical-device DHCP/DNS requires the TP-Link UE300 USB-A gigabit NIC documented in `docs/HARDWARE.md`; that NIC will become a physical OpenWrt LAN bridge (`vmbr2`) connected to the Archer AP/switch.

Management commands from Tiamat:
```
qm terminal 100
ssh root@10.10.0.1
qm agent 100 ping
```

Setup script: `proxmox/setup-openwrt-vm.sh` creates `vmbr1`, imports the OpenWrt x86/64 EFI image, configures WAN/LAN assignment, installs LuCI and qemu guest agent, and verifies the VM.

## Proxmox Bridge
Proxmox host networking is bridged through `vmbr0` so all existing CTs/VMs get LAN access. `vmbr1` is a virtual-only internal bridge for the OpenWrt VM LAN; it has no physical port until the TP-Link UE300 USB NIC arrives.

`/etc/network/interfaces`:
```
auto lo
iface lo inet loopback

auto enp4s0
iface enp4s0 inet manual

auto vmbr0
iface vmbr0 inet static
    address 192.168.12.242/24
    gateway 192.168.12.1
    bridge-ports enp4s0
    bridge-stp off
    bridge-fd 0
    dns-nameservers 192.168.12.244

auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-multicast-snooping 0
```

## Core Service Map

> **Consolidated 2026-05-22**: All Proxmox LXC services merged into CT-300.
> **2026-05-28**: CT-501 `habridge` added for Alexa/Hue voice control.

### Proxmox host
| Service | URL |
|---|---|
| Proxmox UI | `https://192.168.12.242:8006` |

### HABridge — Alexa voice bridge (CT-501, port 80)
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
| VM-100 `openwrt` | OpenWrt router/control plane | `10.10.0.1` LAN / `192.168.12.x` WAN | WAN on `vmbr0`, LAN on virtual `vmbr1`, LuCI + qemu-ga enabled |
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

## VPN Architecture

**Active (2026-06-06).** PiVPN + WireGuard on Bahamut. All systems behind VPN.

Server: Bahamut (`192.168.12.244:51820`), PiVPN, subnet `10.92.29.0/24`.
IP forwarding + NAT masquerade on Bahamut forwards all client traffic.

| Client | VPN IP | Config | Boot |
|---|---|---|---|
| Laptop | 10.92.29.2 | `/etc/wireguard/wg0.conf` | `systemctl enable wg-quick@wg0` |
| Tiamat | 10.92.29.3 | `/etc/wireguard/wg0.conf` | `systemctl enable wg-quick@wg0` |
| OpenWrt VM-100 | 10.92.29.4 | UCI `network.wg0` | persistent (UCI) |
| CT-300 mediastack | 10.92.29.5 | `/etc/wireguard/wg0.conf` | `systemctl enable wg-quick@wg0` |

All clients use full tunnel (`AllowedIPs = 0.0.0.0/0`) with `Endpoint = 192.168.12.244:51820`.
DNS through VPN: `10.92.29.1` (Bahamut WG interface → AdGuard Home).

Manage clients: `ssh bahamut "pivpn -l"` / `pivpn add -n <name>` / `pivpn -r <name>`.
Tray widget on laptop: `~/wireguard-tools/tray-widget/wireguard-tray-widget.py`.

**Old architecture (decommissioned):** CT-100 WG server, CT-101 WG proxy + TinyProxy,
wg-easy Docker on Bahamut. Preserved in `infrastructure/wireguard-server/` for reference.

### aria2 Fallback Download Path

When Real-Debrid refuses a torrent (DMCA, dead, uncached), aria2 in CT-300
downloads it directly via BitTorrent through the WireGuard tunnel.

| Component | Location | Port |
|---|---|---|
| aria2 daemon | CT-300 | 6800 (JSON-RPC) |
| riven-aria2-bridge | CT-300 | — (polls Riven API) |
| AriaNg (optional) | — | — |

Config: `/etc/aria2/aria2.conf`, RPC secret: `mediastack-aria2`.
Bridge: `/opt/riven-aria2-bridge.py`, polls Riven Failed items every 60s.
State: `/var/lib/riven-aria2-bridge/state.db`.
Downloads to: `/data/media/downloads/`, then Jellyfin picks up via library scan.

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

Bahamut (`192.168.12.244`, Raspberry Pi 4, DietPi / Debian 13) is the native
edge-services node. It uses fish as root's login shell.

Native services:
- AdGuard Home: DNS `:53`, admin UI `http://192.168.12.244:8081`
  - Rewrite: `*.tiamat.local → 192.168.12.30` (CT-300 Caddy)
  - Required explicit rewrites: `habridge.tiamat.local → 192.168.12.30`,
    `ha.tiamat.local → 192.168.12.30`
- Caddy + DuckDNS: native `/usr/local/bin/caddy`, systemd `caddy.service`,
  TLS for `*.lou-fogle-media-stack.duckdns.org`
  - `vaultwarden.*` → `localhost:8080`
  - `adguard.*` → `localhost:8081`
  - `ha.*` → `192.168.12.123:8123` (Home Assistant VM-990)
- Vaultwarden: native ARM64 binary built on the laptop and deployed to
  `/usr/local/bin/vaultwarden`, systemd `vaultwarden.service`, data in
  `/opt/appdata/vaultwarden`
- DietPi Dashboard: `:5252`
- TigerVNC: `:5901`

- PiVPN + WireGuard: VPN server `:51820/udp`, subnet `10.92.29.0/24`
  - Clients: laptop, tiamat, openwrt, mediastack (see VPN Architecture)

Removed from active Bahamut architecture:
- Docker / containerd
- wg-easy (replaced by native PiVPN)
- Docker Caddy image

> **Tailscale removed from Bahamut (2026-05-22).** Tailscale now runs inside
> CT-300 as `tiamat-tailscale` (`100.115.82.71`).

Router DNS recommendation:
1. `192.168.12.244`
2. `1.1.1.1`
