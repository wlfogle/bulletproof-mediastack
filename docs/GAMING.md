# Gaming

> **Historical/reference note:** This document may describe an older pre-NexusOS or pre-Riven architecture. Current live source of truth is `docs/NETWORKING.md`, `docs/NEXUSOS-COMPONENT.md`, and `README.md`. WireGuard, wg-easy, CT-100/CT-101, Traefik, Authentik, zurg, rclone, Docker-first Bahamut, and old multi-CT *arr flows are not active unless a current doc explicitly says otherwise.


## ROM Collection — Tiamat `/mnt/hdd/media/roms/`
All ROMs live on Tiamat's 2TB HDD (always available, no laptop dependency).

| System | Folder | ROMs | Size |
|--------|--------|------|------|
| Atari 2600 | `atari2600/` | 834 | 10MB |
| Gameboy Advance | `gba/` | 102 | 386MB |
| MAME/Arcade | `arcade/` | 1,047 | 85MB |
| Neo Geo | `neogeo/` | 517 | 2.8GB |
| Nintendo 64 | `n64/` | 49 | 702MB |
| NES | `nes/` | 2,123 | 224MB |
| Sega Master System | `mastersystem/` | 401 | 46MB |
| Sega Genesis | `megadrive/` | 956 | 634MB |
| SNES | `snes/` | 837 | 660MB |
| TurboGrafx-16 | `pcengine/` | 683 | 93MB |
| ZX Spectrum | `zxspectrum/` | 13 | 5MB |
| Nintendo Switch | `switch/` | 13 | 89GB |

**Total: 7,575 retro + 13 Switch = 94GB**

Source: retro from `6666 games in 1 Ultimate Classic Games Collection [Retro Legends]` ISO,
Switch NSPs from laptop `/media/loufogle/Games/roms/`.

## Gaming CT (CT-280 — RetroPie)
- RetroPie + EmulationStation on Debian LXC
- Bind mount: `/mnt/hdd/media/roms` → `/home/pi/RetroPie/roms`
- Access: VNC or `http://games.tiamat.local` via Traefik (EmulationStation web)
- Play from: laptop, Fire TV (Moonlight/VNC), any device on LAN

## Windows Gaming VM (VM-900)
- Windows 11 on Tiamat (`pc-q35-11.0`, OVMF/UEFI)
- **RX 580 GPU passthrough** (VFIO, `pcie=1,x-vga=1`) — exclusively for gaming
- 150GB virtio OS disk on local-ssd
- 16GB RAM, **4 vCPUs** (`cpu: host,hidden=1` — KVM hidden for anti-cheat)
- AMD Adrenalin **26.5.2** installed (5/20/2026)
- Access: NoMachine remote desktop or direct HDMI/DP from RX 580

### Gaming Optimizations Applied (2026-05-29)
- Proxmox: `cpu: host,hidden=1` — hides KVM hypervisor from anti-cheat
- Proxmox: 4 cores (up from 2)
- Windows: High Performance power plan active
- Windows: Hardware Accelerated GPU Scheduling (HAGS) enabled
- Windows: GPU MSI (Message Signaled Interrupts) enabled
- Windows: Xbox Game DVR/Bar disabled
- Windows: Fullscreen Optimizations disabled globally
- Windows: Visual Effects set to Performance
- AMD Adrenalin: Graphics Profile set to Performance

> CT-300 (mediastack) switched to software decoding so the RX 580
> is dedicated exclusively to VM-900. See `docs/HARDWARE.md`.

## Windows Gaming VM (VM-901) — Legacy/Archived
- Retired — replaced by VM-900 with direct GPU passthrough
- PlayOn Home saves to `/mnt/hdd/media/playon` → Plex/Jellyfin
- With 32GB RAM, can now run alongside the full media stack

## Fire TV Gaming
- **Retro**: RetroArch from App Store, NFS ROMs from `192.168.12.242:/mnt/hdd/media/roms`
- **Web**: RetroArch Web at `http://games.tiamat.local` via Silk Browser
- **Switch/PC streaming**: Moonlight on Fire TV → Sunshine on laptop (RTX 4080)
- See `docs/RETRO-GAMING.md` for detailed Fire TV setup

## Laptop Gaming
- **Ryubing** (Switch emulator) via snap: `/snap/bin/ryubing-emulator`
- **Sunshine** game-stream host — running as user service
  - Installed: `~/.local/bin/Sunshine.AppImage` (official LizardByte AppImage)
  - Service: `sunshine-appimage.service` (enabled, starts with graphical session)
  - Web UI: `https://localhost:47990` (credentials: sunshine / sunshine — change after first login)
  - Configured apps: Desktop, Switch (Ryubing), Steam Big Picture
  - Required: Ubuntu Toolchain PPA (`ppa:ubuntu-toolchain-r/test`) for libstdc++6 ≥ GLIBCXX_3.4.32

### Streaming to Moonlight clients
- Install **Moonlight** on Fire TV / phone / another laptop
- Connect to laptop IP (LAN) or Tailscale IP (remote)
- Pair once via PIN shown in Sunshine web UI
- Launch "Switch (Ryubing)" app directly from Moonlight

> **Full setup guide**: `docs/SUNSHINE-MOONLIGHT.md`
