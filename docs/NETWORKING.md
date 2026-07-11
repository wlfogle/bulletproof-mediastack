# Networking

## LAN Layout

```
Spectrum SAX1V1K (192.168.1.1) — WAN: 74.134.128.100 (real public IP), DHCP 192.168.1.x
  ├── Laptop enp4s0 (direct)         → 192.168.1.188 (wired, DHCP)
  └── Archer AX55 Pro "Stella" — Router mode (WAN: 192.168.1.61 / LAN: 192.168.12.1)
        ├── Tiamat (Proxmox VE)      → 192.168.12.242 (static)
        │     └── UE300 USB NIC → vmbr2 → OpenWrt VM eth2 → br-lan (10.10.0.1/24)
        ├── Bahamut (Raspberry Pi 4) → 192.168.12.244 (static, DietPi edge node)
        ├── Laptop wlp0s20f3 (Stella WiFi) → DHCP (192.168.12.x)
        ├── Fire TV ×2               → DHCP
        └── Phones ×2               → DHCP
```

> **ISP migration 2026-07-11:** Switched from T-Mobile KVD21 (CGNAT) to Spectrum gigabit.
> Spectrum provides a real public IP — port forwarding and external VPN access now work.
> The Archer AX55 Pro is now in **Router mode** (was AP mode behind T-Mobile).
> The T-Mobile KVD21 is still physically present and broadcasting `Max-5g` on 192.168.12.x
> as a separate network — it is no longer the primary ISP.

Archer admin: `http://192.168.12.1` · Spectrum gateway: `http://192.168.1.1`
See `docs/ARCHER-SETTINGS.md` for optimal Archer configuration.

> **DNS note:** Archer DHCP is configured to push `192.168.12.244` (AdGuard on Bahamut)
> as DNS for all LAN clients. Critical infrastructure (Tiamat, Bahamut, CTs, Home Assistant)
> has static DNS pointing to `192.168.12.244`. See `docs/ARCHER-SETTINGS.md` for DNS config.

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

**2026-07-11: UE300 installed and vmbr2 operational.** OpenWrt LAN bridge (`br-lan`) now includes both `eth1` (vmbr1, virtual) and `eth2` (vmbr2, physical UE300 USB NIC at `enx00e04c3f4188`). The UE300 RJ45 connects to the Archer switch, allowing OpenWrt to serve physical clients.

To disable the Archer's DHCP and let OpenWrt take over fully, set Archer DHCP pool to disabled via `http://192.168.12.1`.

Management commands from Tiamat:

```
qm terminal 100
ssh root@10.10.0.1
qm agent 100 ping
```

Setup script: `proxmox/setup-openwrt-vm.sh` creates `vmbr1`, imports the OpenWrt x86/64 EFI image, configures WAN/LAN assignment, installs LuCI and qemu guest agent, and verifies the VM.

## Proxmox Bridge

Proxmox host networking is bridged through `vmbr0` so all existing CTs/VMs get LAN access. `vmbr1` is a virtual-only internal bridge for the OpenWrt VM LAN. `vmbr2` bridges the UE300 USB NIC (`enx00e04c3f4188`) to OpenWrt's physical LAN port.

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

| Service    | URL                           |
| ---------- | ----------------------------- |
| Proxmox UI | `https://192.168.12.242:8006` |

### HABridge — Alexa voice bridge (CT-501, port 80)

| Service                   | Port     | URL                                               |
| ------------------------- | -------- | ------------------------------------------------- |
| HABridge web UI + Hue API | 80       | `http://192.168.12.251` / `habridge.tiamat.local` |
| UPnP/SSDP discovery       | 1900/udp | (Alexa auto-discovers on LAN)                     |

### CT-300 `mediastack` (192.168.12.30)

All services run inside this single privileged Debian 12 LXC.

| Service                 | Internal port | URL / hostname                                                                                                                  |
| ----------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Riven frontend          | 3000          | `http://192.168.12.30:3000` / `riven.mediastack.lan`                                                                            |
| Riven backend           | 8080          | `http://192.168.12.30:8080`                                                                                                     |
| Jellyfin                | 8096          | `http://192.168.12.30:8096` / `jellyfin.mediastack.lan` / `jellyfin.tiamat.local`                                               |
| n8n                     | 5678          | `http://192.168.12.30:5678` / `n8n.tiamat.local`                                                                                |
| Threadfin (IPTV proxy)  | 34400         | `http://192.168.12.30:34400/web` / `threadfin.tiamat.local`                                                                     |
| Uptime Kuma             | 3001          | `http://192.168.12.30:3001` / `uptime.tiamat.local`                                                                             |
| Homarr (dashboard)      | 7575          | `http://192.168.12.30:7575` / `homarr.mediastack.lan` · board: `/boards/Tiamat-Mediastack` · login: `admin` / `Mediastack2024!` |
| Pulse (Proxmox monitor) | —             | web UI port in `/etc/pulse/.env`                                                                                                |
| Caddy (reverse proxy)   | 80/443        | handles all `*.tiamat.local` + `*.mediastack.lan` routes                                                                        |
| PostgreSQL 15           | 5432          | internal only (`riven` database)                                                                                                |
| Redis                   | 6379          | internal only                                                                                                                   |
| CrowdSec                | 8081          | internal only                                                                                                                   |
| Tailscale               | —             | node `tiamat-tailscale` · `100.115.82.71` · funnel `https://tiamat-tailscale.tail9d8b73.ts.net`                                 |

**Decommissioned CTs (2026-05-22):** CT-102 (n8n-stable), CT-103 (Traefik), CT-104 (Vaultwarden), CT-105 (Valkey), CT-106 (Postgres), CT-107 (Authentik), CT-110 (Pulse), CT-200 (HA DuckDNS proxy), CT-234 (Threadfin), CT-248 (Uptime Kuma), CT-279 (Tailscale)
**Running CTs (2026-05-28):** CT-300 `mediastack` (192.168.12.30), CT-501 `habridge` (192.168.12.251)
Vaultwarden backup: `/var/backup/mediastack/vaultwarden_pg_dump.sql` + `vaultwarden_data.tgz` in CT-300.

### VMs

| VM               | Purpose                      | IP                                    | Notes                                                      |
| ---------------- | ---------------------------- | ------------------------------------- | ---------------------------------------------------------- |
| VM-100 `openwrt` | OpenWrt router/control plane | `10.10.0.1` LAN / `192.168.12.x` WAN  | br-lan: eth1 (vmbr1) + eth2 (vmbr2/UE300); SSH via `ssh openwrt` |
| VM-101 `win11vm` | Windows 11 gaming            | DHCP (192.168.12.x)                   | RX 580 GPU passthrough; disk moved to local-lvm 2026-07-11 |
| VM-990 `haos`    | Home Assistant OS            | `192.168.12.123` (static)             | Smart home hub                                             |

### Laptop NFS Exports (192.168.12.172)

| Export path                              | Tiamat mount               | Consumer                            |
| ---------------------------------------- | -------------------------- | ----------------------------------- |
| `/media/loufogle/Data/Calibre Library`   | `/mnt/laptop/calibre`      | CT-233 Calibre-Web                  |
| `/media/loufogle/Data/Cookbooks`         | `/mnt/laptop/cookbooks`    | CT-233 second library               |
| `/media/loufogle/SystemBackup/Videos`    | `/mnt/laptop/videos`       | Plex / Jellyfin Home Videos         |
| `/media/loufogle/ISOs1`                  | `/mnt/laptop/isos`         | Proxmox ISO uploads                 |
| `/media/loufogle/Games/roms`             | `/mnt/laptop/roms`         | Future emulation frontend           |
| `/media/loufogle/Data/Downloads/lou.m3u` | `/mnt/laptop/iptv/lou.m3u` | Jellyfin Live TV / TVHeadend CT-235 |

See `docs/NFS.md` for setup.

## VPN Architecture

**Active (2026-06-06).** PiVPN + WireGuard on Bahamut. All systems behind VPN.

Server: Bahamut (`192.168.12.244:51820`), PiVPN, subnet `10.92.29.0/24`.
IP forwarding + NAT masquerade on Bahamut forwards all client traffic.

| Client            | VPN IP     | Config                    | Boot                            |
| ----------------- | ---------- | ------------------------- | ------------------------------- |
| Laptop            | 10.92.29.2 | `/etc/wireguard/wg0.conf` | `systemctl enable wg-quick@wg0` |
| Tiamat            | 10.92.29.3 | `/etc/wireguard/wg0.conf` | `systemctl enable wg-quick@wg0` |
| OpenWrt VM-100    | 10.92.29.4 | UCI `network.wg0`         | persistent (UCI)                |
| CT-300 mediastack | 10.92.29.5 | `/etc/wireguard/wg0.conf` | `systemctl enable wg-quick@wg0` |

All clients use full tunnel (`AllowedIPs = 0.0.0.0/0`).
LAN clients use `Endpoint = 192.168.12.244:51820`.
Remote clients use `Endpoint = 74.134.128.100:51820` (Spectrum public IP, port-forwarded on Archer).
DNS through VPN: `10.92.29.1` (Bahamut WG interface → AdGuard Home).

> **Bahamut throughput ceiling:** The Pi 4's Gigabit Ethernet runs over an internal USB 3.0 bus,
> limiting real-world throughput to ~500 Mbps down / ~200 Mbps up regardless of ISP or router.
> Moving Bahamut to the Spectrum subnet would not improve this and would break LAN DNS
> (`192.168.12.244`) and internal WireGuard endpoints for all clients. Bahamut's workloads
> (DNS queries + WireGuard handshakes) do not require gigabit throughput.
> If full-gigabit VPN throughput is ever needed, migrate the WireGuard server to Tiamat
> (real gigabit NIC, no USB bottleneck) and update all client configs + the Archer port-forward.

Manage clients: `ssh bahamut "pivpn -l"` / `pivpn add -n <name>` / `pivpn -r <name>`.
Tray widget on laptop: `~/wireguard-tools/tray-widget/wireguard-tray-widget.py`.

**Old architecture (decommissioned):** CT-100 WG server, CT-101 WG proxy + TinyProxy,
wg-easy Docker on Bahamut. Preserved in `infrastructure/wireguard-server/` for reference.

### aria2 Fallback Download Path

When Real-Debrid refuses a torrent (DMCA, dead, uncached), aria2 in CT-300
downloads it directly via BitTorrent through the WireGuard tunnel.

| Component          | Location | Port                |
| ------------------ | -------- | ------------------- |
| aria2 daemon       | CT-300   | 6800 (JSON-RPC)     |
| riven-aria2-bridge | CT-300   | — (polls Riven API) |
| AriaNg (optional)  | —        | —                   |

Config: `/etc/aria2/aria2.conf`, RPC secret: `mediastack-aria2`.
Bridge: `/opt/riven-aria2-bridge.py`, polls Riven Failed items every 60s.
State: `/var/lib/riven-aria2-bridge/state.db`.
Downloads to: `/data/media/downloads/`, then Jellyfin picks up via library scan.

## Caddy Reverse Proxy (CT-300)

All `*.tiamat.local` and `*.mediastack.lan` hostnames are served by Caddy **inside CT-300** at `192.168.12.30:80/443`.
DNS wildcard: `*.tiamat.local → 192.168.12.30` via AdGuard rewrite on Bahamut.
Config: `infrastructure/caddy/Caddyfile` (also live at `/etc/caddy/Caddyfile` in CT-300).

| Hostname                                         | Service                   | Backend               |
| ------------------------------------------------ | ------------------------- | --------------------- |
| `riven.mediastack.lan`, `riven.local`            | Riven UI                  | `127.0.0.1:3000`      |
| `jellyfin.mediastack.lan`, `jellyfin.local`      | Jellyfin                  | `127.0.0.1:8096`      |
| `n8n.tiamat.local`                               | n8n                       | `127.0.0.1:5678`      |
| `uptime.tiamat.local`, `uptimekuma.tiamat.local` | Uptime Kuma               | `127.0.0.1:3001`      |
| `threadfin.tiamat.local`                         | Threadfin                 | `192.168.12.30:34400` |
| ha.tiamat.local, homeassistant.tiamat.local      | Home Assistant VM-990     | `192.168.12.123:8123` |
| habridge.tiamat.local                            | HABridge CT-501           | `192.168.12.251:80`   |
| `sonarr.tiamat.local`                            | Sonarr (stopped CT-214)   | `192.168.12.214:8989` |
| `radarr.tiamat.local`                            | Radarr (stopped CT-215)   | `192.168.12.225:7878` |
| `prowlarr.tiamat.local`                          | Prowlarr (stopped CT-210) | `192.168.12.210:9696` |
| `homarr.mediastack.lan`, `homarr.local`          | Homarr dashboard          | `127.0.0.1:7575`      |
| `guide.mediastack.lan`, `guide.local`            | Guide / Meilisearch       | `127.0.0.1:7700`      |
| `cockpit.mediastack.lan`                         | Cockpit                   | `127.0.0.1:9090`      |

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

## Device Inventory

> Updated 2026-07-11 post Spectrum migration. Subnet: `192.168.12.0/24` behind Archer AX55 Pro.
> MACs are the stable identifier for DHCP clients. IPs are reference only.

### Infrastructure (static)

| IP             | Device                          | MAC               | Notes                              |
| -------------- | ------------------------------- | ----------------- | ---------------------------------- |
| 192.168.12.1   | Archer AX55 Pro "Stella" (LAN)  | 24:2F:D0:28:E0:06 | Router mode, WAN: 192.168.1.61     |
| 192.168.12.242 | Tiamat (Proxmox host)           | B4:2E:99:AA:CF:06 | Gigabyte; enp4s0 in vmbr0          |
| 192.168.12.244 | Bahamut (Pi 4, eth0)            | 88:A2:9E:85:CD:E6 | AdGuard DNS / WireGuard server     |
| 192.168.12.245 | Bahamut (Pi 4, wlan0)           | 88:A2:9E:85:CD:E7 | secondary iface                    |
| 192.168.12.30  | CT-300 mediastack               | BC:24:11:E3:7C:DB | Jellyfin/Riven/n8n/Caddy           |
| 192.168.12.123 | VM-990 Home Assistant OS        | 02:88:F9:77:28:E2 | Smart home hub                     |
| 192.168.12.201 | CT-200 alexa-media-bridge       | BC:24:11:30:1C:C2 | static .201                        |
| 192.168.12.251 | CT-501 HABridge                 | BC:24:11:AB:A3:2D | Alexa/Hue bridge                   |
| 192.168.12.215 | HDHomeRun tuner                 | 00:18:DD:04:8E:EE | HDHR-1048EEE4                      |
| 192.168.12.198 | Epson ET-2850 printer           | 68:55:D4:34:0E:C8 | EPSON340EC8                        |

### VM-100 OpenWrt (DHCP WAN, static LAN)

| Interface | IP            | Notes                              |
| --------- | ------------- | ---------------------------------- |
| eth0 WAN  | DHCP (~.134)  | vmbr0, gets lease from Archer      |
| br-lan    | 10.10.0.1/24  | eth1 (vmbr1) + eth2 (vmbr2/UE300) |

### Laptop (dual connection)

| Interface  | Network          | IP              |
| ---------- | ---------------- | --------------- |
| enp4s0     | Spectrum direct  | 192.168.1.188   |
| wlp0s20f3  | Archer Stella    | DHCP 192.168.12.x |

### Endpoints (DHCP)

| Device                 | MAC               | Notes                    |
| ---------------------- | ----------------- | ------------------------ |
| Fire TV — living room  | 78:A0:3F:2D:B9:E0 |                          |
| Fire TV — bedroom      | D8:E7:43:20:7C:64 |                          |
| Galaxy Note 20 (phone) | —                 |                          |
| Android tablet         | —                 |                          |
| Galaxy S10 (2nd phone) | —                 |                          |

### Unidentified

| MAC               | Last IP        | Vendor                | Status / Notes                                              |
| ----------------- | -------------- | --------------------- | ----------------------------------------------------------- |
| 5C:E7:53:45:EA:3E | 192.168.12.140 | Shenzhen Intellirocks | Unknown IoT device — **Device Isolation applied on Archer** (2026-07-11); retains internet, blocked from LAN |
| 00:E5:AC:3F:D0:5E | 192.168.12.169 | Unknown OUI           | Stale DHCP lease (hostname: "tiamat"); offline, not in any Proxmox config; investigated 2026-07-11, not a security concern |

> Re-run discovery: `sudo nmap -sn 192.168.12.0/24` from laptop on Stella WiFi (wlp0s20f3).
> MAC vendor lookup: `curl https://api.macvendors.com/<MAC>`.
