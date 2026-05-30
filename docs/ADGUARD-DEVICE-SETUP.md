# AdGuard DNS — Device Setup Guide

**AdGuard Home:** `192.168.12.244` port `53` · Admin UI: `http://192.168.12.244:8081`

AdGuard Home is already running on Bahamut (`192.168.12.244`). This guide covers pointing every device on the LAN at it as their DNS server.

---

## Step 1 — Router (covers all DHCP devices automatically)

Go to `http://192.168.12.1` → DHCP settings → set DNS servers:

- **Primary DNS:** `192.168.12.244`
- **Secondary DNS:** `1.1.1.1`

This propagates to all DHCP clients (phones ×2, Fire TVs ×2, laptop if not static) on lease renewal. Highest-leverage single change.

---

## Step 2 — Tiamat (Proxmox host, 192.168.12.242)

`/etc/network/interfaces` currently has `dns-nameservers 192.168.12.1`. Change it:

```
dns-nameservers 192.168.12.244
```

Then restart networking:

```bash
systemctl restart networking
# or
ifreload -a
```

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
