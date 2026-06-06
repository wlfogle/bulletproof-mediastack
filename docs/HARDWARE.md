# Hardware Documentation

## Server — CyberPowerPC C Series ET8890-37125 (Tiamat @ 192.168.12.242 post-Proxmox)

> Specs confirmed via SSH + PowerShell query on 2026-03-13

| Component | Spec |
|-----------|------|
| **CPU** | AMD Ryzen 5 3600, 6-core / 12-thread, 3.6GHz base / 4.2GHz boost |
| **RAM** | 32GB DDR4-3200 — two sticks, **2 slots free** |
| **GPU** | XFX Radeon RX 580 Series, 4GB VRAM, Driver 31.0.21924.61 |
| **Motherboard** | Gigabyte B450M DS3H WIFI-CF (MicroATX, AM4 socket) |
| **Storage (OS)** | 240GB WD SSD |
| **Storage (Media)** | 2TB WD HDD |
| **Storage (External)** | 240GB Kingston SSD (USB) + 2GB USB flash drive |
| **PSU** | 450W |
| **Networking** | Gigabit Ethernet + 802.11AC Wi-Fi (onboard) |
| **OS** | Proxmox 9.2.3 |
| **Build date** | ~March 2020 |
| **Chassis** | Full tower, tempered glass side panel |
| **Service number** | 888-937-5582 |

## Recommended Upgrades

1. **RAM** ✅ UPGRADED: 32GB DDR4-3200 (was 8GB, upgraded 2026-03-26)
   - VM-901 can now run alongside the full media stack
   - FlareSolverr Cloudflare solving now possible (Chrome headless needs ~2GB)
   - B450M DS3H supports up to 128GB across 4 slots (2 slots used)
2. **OS**: Migrated to Proxmox VE ✅
3. **Storage**: 2TB WD HDD in use for media. 240GB WD SSD (sdb) passed through to VM-901 for games.
4. **Network**: Use wired Ethernet — avoid Wi-Fi for streaming stability
5. **USB NIC** ⏳ PENDING: TP-Link UE300 (USB-A 3.0, RTL8153 chipset, ~$12) — needed to extend OpenWrt VM LAN to physical devices (phones, Fire TVs, laptop). Plug into any USB-A port (rear or top panel). Will become `vmbr2` bridge → OpenWrt LAN NIC → Archer AP switch → all physical devices get DHCP/DNS from OpenWrt+AdGuard. Until it arrives, OpenWrt serves CTs/VMs only.

## GPU Passthrough Status

RX 580 (XFX) is **fully configured for VFIO passthrough** — no setup needed:
- `amd_iommu=on iommu=pt` in GRUB cmdline ✅
- IOMMU Group 2: `09:00.0` (GPU) + `09:00.1` (HDMI audio) — clean group ✅
- Both functions bound to `vfio-pci` driver ✅
- VFIO PCI IDs: `1002:67df,1002:aaf0` in `/etc/modprobe.d/vfio-pci.conf` ✅
- `vfio_iommu_type1 allow_unsafe_interrupts=1` set ✅

> With GPU passed through, Proxmox host is **headless** — manage via web UI or SSH only.

### GPU Assignment — VM-900 (Windows Gaming VM)

As of 2026-05-29 the RX 580 is dedicated to **VM-900** (Windows gaming VM):

- `/dev/dri` device passthrough **removed** from CT-300 LXC config (`/etc/pve/lxc/300.conf`)
- Jellyfin (CT-300) switched to **software decoding/encoding** — `HardwareAccelerationType=none`, `EnableHardwareEncoding=false`, `HardwareDecodingCodecs` cleared (`/etc/jellyfin/encoding.xml`)
- GPU is now free for exclusive VFIO passthrough to VM-900

To attach the GPU to VM-900 via Proxmox web UI: Hardware → Add → PCI Device → select `09:00.0` (and `09:00.1` for HDMI audio) with PCIe enabled.

## Storage on Tiamat

| Device | Size | Use |
|--------|------|-----|
| sda (ST2000DM008 HDD) | 1.8TB | Proxmox LVM: root (96GB), media-hdd (1.5TB), all CT/VM disks |
| sdb (WDC WDS240G2G0A SSD) | 223GB | Passed through to VM-901 (Windows games storage); contains existing Windows install on sdb4 |

## Bahamut (Raspberry Pi 4, DietPi)

> Bahamut is the current native edge DNS / reverse-proxy / password-manager node. The name
> "Ziggy" is no longer attached to hardware — Ziggy now refers to CT-900
> (Open WebUI + SearXNG) running as an LXC on Tiamat.

| Component | Spec |
|-----------|------|
| **CPU** | Broadcom BCM2711, quad-core Cortex-A72 @ 1.5 GHz (64-bit) |
| **RAM** | 2 GB class Pi memory (observed 1.8 GiB usable) |
| **Storage** | microSD + optional USB SSD for swap (recommended) |
| **Networking** | Gigabit Ethernet + 802.11AC Wi-Fi (use wired) |
| **OS** | DietPi on Debian 13 (trixie) |
| **IP** | 192.168.12.244 (static) |
| **Services** | Native AdGuard Home (`:53`, `:8081`), native Caddy + DuckDNS (`:80`, `:443`), native Vaultwarden (`:8080` behind Caddy), DietPi Dashboard, TigerVNC |

> Docker, wg-easy, and WireGuard are removed from Bahamut. Vaultwarden is fronted
> by native Caddy for automatic TLS. AdGuard is the LAN primary resolver.

## Laptop — Primary Admin / Dev Machine

| Component | Spec |
|-----------|------|
| **OS** | Pop!_OS 22.04 LTS (KDE Plasma 5.24.7) |
| **Kernel** | 6.17.9-76061709-generic (64-bit) |
| **CPU** | Intel Core i9-13900HX, 24-core (8P+16E) / 32-thread, 13th Gen |
| **RAM** | 62.5 GB |
| **GPU (integrated)** | Intel Arc / Intel Xe Graphics (Mesa) |
| **GPU (discrete)** | NVIDIA GeForce RTX 4080 (laptop) |
| **Graphics platform** | X11 |
| **Role** | Primary admin workstation, repo dev, Proxmox SSH, Android APK builds |

> NVIDIA RTX 4080 available for CUDA workloads — useful for AI/transcoding experiments.
> Android APK builds run here (Java 17 + Android SDK).

## Client Devices

| Device | Role |
|--------|------|
| 2x Fire TV + Fire TV Cube | Jellyfin + Plex, Homarr/Overseerr via Silk Browser, nzb360 sideload, TiamatsStack APK |
| Android (tablet/phone) | Jellyfin, Plex, nzb360, Bitwarden |
| Laptop (i9-13900HX) | Proxmox admin, Homarr, MediaStack Control, SSH, APK builds |

## Network Requirements

- All devices on the same LAN for local streaming
- Server should have a static LAN IP (set via router DHCP reservation or Proxmox static config)
- Gigabit router/switch recommended for smooth 1080p/4K local streaming
