# AdGuard DNS — Device Setup Guide

**AdGuard Home:** `192.168.12.244` port `53` · Admin UI: `http://192.168.12.244:8081`

AdGuard Home is already running on Bahamut (`192.168.12.244`). This guide covers pointing every device on the LAN at it as their DNS server.

---

## Step 1 — Router ✅ DONE (Archer AX55 Pro)

Since the 2026-07-11 Spectrum migration the Archer AX55 Pro (`http://192.168.12.1`) is in
**Router mode** and DHCP is configured to push `192.168.12.244` as DNS to all clients.
All DHCP devices (Fire TVs, phones, laptop WiFi) automatically receive AdGuard DNS — no
per-device configuration needed for those clients.

Static-IP hosts (Tiamat, Bahamut, CTs, VMs) still require explicit DNS config per the steps below.

---

## Step 2 — Tiamat (Proxmox host, 192.168.12.242) ✅ DONE

`/etc/network/interfaces` has `dns-nameservers 192.168.12.244` (already set).

---

## Step 3 — CT-300 (mediastack, 192.168.12.30)

CTs inherit DNS from the Proxmox host — fixing Step 2 above may already cover this. Verify:

```bash
pct exec 300 -- bash -c "cat /etc/resolv.conf"
```

If `/etc/resolv.conf` still shows `192.168.12.1`, update it to `192.168.12.244` inside the CT.

---

## Step 4 — VM-990 (Home Assistant OS, 192.168.12.123)

```bash
ha network update enp6s18 --ipv4-dns 192.168.12.244
```

Same pattern as the static IP documented in `docs/NETWORKING.md`.

---

## Step 5 — VM-101 win11vm (Windows 11 Gaming, DHCP)

VM-101 gets its IP via DHCP from the Archer, so it already receives `192.168.12.244` as DNS
automatically (Step 1). If DNS was previously set statically inside Windows, clear it:

Windows Settings → Network → Ethernet/WiFi adapter → IPv4 Properties → DNS:

- Set both fields to **Obtain DNS server address automatically**

Or to keep it static:

- **Preferred:** `192.168.12.244`
- **Alternate:** `1.1.1.1`

---

## Step 6 — Laptop (192.168.12.172, Pop!_OS)

```bash
nmcli con mod "$(nmcli -g NAME con show --active)" \
  ipv4.dns "192.168.12.244 1.1.1.1" \
  ipv4.ignore-auto-dns yes
nmcli con up "$(nmcli -g NAME con show --active)"
```

---

## Step 7 — Bahamut itself (192.168.12.244, DietPi)

Do **not** point Bahamut at itself. AdGuard manages its own upstream resolvers (e.g. `1.1.1.1`). No change needed here.

---

## Verification

After each device change:

```bash
# Confirm AdGuard responds
dig +short google.com @192.168.12.244

# Confirm local rewrites resolve
dig +short jellyfin.tiamat.local
```

The wildcard rewrite `*.tiamat.local → 192.168.12.30` in AdGuard is the key dependency for all Caddy-served local hostnames. Once all devices use AdGuard DNS, those hostnames resolve everywhere on the LAN automatically.


## OpenWrt/UE300 — Current State (2026-07-11)

The TP-Link UE300 is installed and `vmbr2` is operational. OpenWrt VM-100's `br-lan`
now includes `eth2` (vmbr2/UE300), whose RJ45 connects to the Archer switch.

The Archer currently handles DHCP/DNS for the `192.168.12.0/24` LAN and pushes
`192.168.12.244` to all clients. To hand full DHCP/DNS control to OpenWrt instead,
disable the Archer's DHCP pool at `http://192.168.12.1` and configure OpenWrt to
serve `192.168.12.244` as DNS in its DHCP options. At that point this per-device
guide becomes fallback-only, and firewall rules on OpenWrt can prevent clients from
bypassing AdGuard.
