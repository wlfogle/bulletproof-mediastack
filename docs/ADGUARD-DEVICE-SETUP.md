# AdGuard DNS — Device Setup Guide

**AdGuard Home:** `192.168.12.244` port `53` · Admin UI: `http://192.168.12.244:8081`

AdGuard Home is already running on Bahamut (`192.168.12.244`). This guide covers pointing every device on the LAN at it as their DNS server.

---

## Step 1 — Router ⚠️ NOT POSSIBLE WITH KVD21

The T-Mobile KVD21 gateway (`http://192.168.12.1`) has **no configurable settings** —
DHCP DNS is locked and cannot be changed via the app or web UI.
Per-device DNS configuration (Steps 2–6 below) is the only option.

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

## Step 5 — VM-901 (Windows Gaming, 192.168.12.201)

Windows Settings → Network → Ethernet/WiFi adapter → IPv4 Properties → DNS:

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


## Future OpenWrt/UE300 path

When the TP-Link UE300 is plugged into Tiamat and passed through/bridged to
VM-100, OpenWrt becomes the DHCP/DNS control plane for physical devices. At
that point this per-device guide becomes fallback-only: OpenWrt DHCP should
hand out `192.168.12.244` as DNS to phones, Fire TVs, laptops, CTs, and VMs,
and firewall rules can prevent clients from bypassing AdGuard.
