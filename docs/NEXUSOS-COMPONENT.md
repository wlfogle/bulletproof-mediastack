# NexusOS Component: bulletproof-mediastack
`bulletproof-mediastack` is the first major NexusOS component. It is both the live homelab/media-stack source of truth and the prototype for the future NexusOS media/network module.

## Component role
This repo provides the first complete NexusOS service module:
- Native Proxmox/LXC deployment pattern
- CT-300 media core: Riven, RivenVFS, Jellyfin, PostgreSQL, Redis, Caddy, CrowdSec
- VM-100 OpenWrt routing/DHCP/DNS control-plane prototype
- Bahamut edge services: native AdGuard Home, native Caddy + DuckDNS, native Vaultwarden
- Fish shell operational standard
- Real-Debrid-first media acquisition path that removes the need for torrent VPN plumbing

## What is current
- CT-300 is the consolidated native media-stack container.
- VM-100 OpenWrt is working as a virtual router on `vmbr1`; physical LAN control waits for the UE300 USB NIC.
- Bahamut is native, not Docker-first.
- WireGuard, wg-easy, CT-100, CT-101, Traefik, Authentik, zurg, and rclone are not active architecture.

## Import path into NexusOS
Future NexusOS should treat this repo as a module source, not merely documentation:
- `proxmox/` → NexusOS homelab/provisioning module
- `scripts/deploy.sh` → native service deployment reference
- `bahamut/` → edge-services module
- `docs/` → operator runbooks and failure-history references
- `services/` → reusable dashboard/guide services where still active

## Preservation rule
Do not delete working source code just because an earlier architecture is obsolete. Either update it, move it into a clearly labeled historical archive, or map it into the NexusOS component inventory.
