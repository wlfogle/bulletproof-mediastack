# AdGuard DNS — Device Setup Guide

**AdGuard Home:** `192.168.12.244` port `53` · Admin UI: `http://192.168.12.244:8081`

AdGuard Home runs natively on Bahamut. This guide covers setting `192.168.12.244` as
the DNS server on every static-IP host in the stack. DHCP clients receive it automatically
from the Archer (Step 1).

---

## Step 1 — Router ✅ DONE (Archer AX55 Pro)

The Archer is in Router mode and DHCP is configured to push `192.168.12.244` to all
clients. **All DHCP devices (Fire TVs, phones, laptop WiFi) are already covered — nothing
to do for them.**

Verify at `http://192.168.12.1` → Advanced → Network → DHCP Server:
- DNS 1: `192.168.12.244`
- DNS 2: `1.1.1.1`

Only static-IP hosts (Tiamat, CTs, VMs) need manual config per the steps below.

---

## Step 2 — Tiamat (Proxmox host, 192.168.12.242) ✅ DONE

**Already set.** `/etc/network/interfaces` contains `dns-nameservers 192.168.12.244`.

Verify:
```bash
ssh root@192.168.12.242 "cat /etc/resolv.conf"
# Expected: nameserver 192.168.12.244
```

If not set, add it to the `vmbr0` block in `/etc/network/interfaces`:
```bash
ssh root@192.168.12.242
# Edit /etc/network/interfaces, add under vmbr0:
#   dns-nameservers 192.168.12.244
systemctl restart networking
```

---

## Step 3 — CT-300 (mediastack, 192.168.12.30)

LXC containers inherit the Proxmox host's `dns-nameservers` setting by default unless
they override it in their container config.

**Check current DNS inside CT-300:**
```bash
pct exec 300 -- bash -c "cat /etc/resolv.conf"
```

**Expected output:**
```
nameserver 192.168.12.244
```

**If it still shows `192.168.12.1` or `8.8.8.8`, fix it two ways:**

Option A — set via Proxmox CT config (persists across reboots):
```bash
# On Tiamat host:
pct set 300 --nameserver 192.168.12.244
pct reboot 300
```

Option B — write directly inside the CT (immediate, persists if not overridden):
```bash
pct exec 300 -- bash -c "echo 'nameserver 192.168.12.244' > /etc/resolv.conf"
```

Verify after fix:
```bash
pct exec 300 -- bash -c "dig +short google.com @192.168.12.244 && echo OK"
```

---

## Step 3b — CT-501 (HABridge, 192.168.12.251)

Same procedure as CT-300.

**Check:**
```bash
pct exec 501 -- bash -c "cat /etc/resolv.conf"
```

**Fix if needed:**
```bash
pct set 501 --nameserver 192.168.12.244
pct reboot 501
```

---

## Step 4 — VM-990 (Home Assistant OS, 192.168.12.123)

HAOS manages networking through its own supervisor. Use the HA CLI via SSH.

**1. SSH into HA:**
```bash
ssh root@192.168.12.123 -p 22222
# (uses the SSH add-on, password: homeassist)
```

**2. Find the network interface name:**
```bash
ha network info
# Look for the interface name (usually enp6s18 or eth0)
```

**3. Set DNS:**
```bash
ha network update enp6s18 --ipv4-dns 192.168.12.244
# Replace enp6s18 with the interface name from step 2 if different
```

**4. Verify:**
```bash
ha network info | grep -A5 nameservers
# Should show 192.168.12.244
```

**Alternative — via HA UI:**
Settings → System → Network → select interface → IPv4 → DNS Servers → set `192.168.12.244`

---

## Step 5 — VM-100 (OpenWrt, 10.10.0.1)

OpenWrt has its own DNS resolver (dnsmasq). Point it at AdGuard as its upstream.

**SSH into OpenWrt from Tiamat:**
```bash
ssh root@10.10.0.1
```

**Set upstream DNS to AdGuard:**
```bash
uci set dhcp.@dnsmasq[0].server='192.168.12.244'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp
service dnsmasq restart
```

**Also push AdGuard DNS to OpenWrt DHCP clients** (devices on the 10.10.0.0/24 subnet):
```bash
uci set dhcp.lan.dhcp_option='6,192.168.12.244'
uci commit dhcp
service dnsmasq restart
```

**Verify from OpenWrt:**
```bash
nslookup jellyfin.tiamat.local 127.0.0.1
# Should resolve to 192.168.12.30
```

---

## Step 6 — VM-101 win11vm (Windows 11 Gaming, DHCP)

VM-101 uses DHCP and already receives `192.168.12.244` automatically from the Archer.
Only action needed is to clear any previously hard-coded static DNS.

**In Windows (run as Administrator):**
```powershell
# Check current DNS:
Get-DnsClientServerAddress -AddressFamily IPv4

# If showing static values, reset to DHCP:
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ResetServerAddresses

# Or set statically if preferred:
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" `
  -ServerAddresses ("192.168.12.244","1.1.1.1")

# Flush DNS cache:
ipconfig /flushdns
```

**Manual UI path:**
Settings → Network & Internet → Ethernet → Edit (next to DNS) →
Set to Manual, IPv4 On, Preferred DNS: `192.168.12.244`, Alternate: `1.1.1.1`

---

## Step 7 — Laptop (Pop!_OS)

The laptop has two active network connections. Set DNS on both.

**7a — Archer WiFi connection (wlp0s20f3, 192.168.12.x):**
```bash
# Find the WiFi connection profile name:
nmcli -g NAME,DEVICE con show --active | grep wlp

# Set DNS (replace 'Stella' with your actual WiFi SSID/profile name):
nmcli con mod "Stella" \
  ipv4.dns "192.168.12.244 1.1.1.1" \
  ipv4.ignore-auto-dns yes
nmcli con up "Stella"
```

**7b — Spectrum wired connection (enp4s0, 192.168.1.188):**
This interface connects to the Spectrum gateway directly (bypasses the Archer/AdGuard).
Leave it using ISP DNS (`1.1.1.1` or auto) unless you want all laptop traffic through AdGuard.
If you do:
```bash
nmcli con mod "Wired connection 1" \
  ipv4.dns "192.168.12.244 1.1.1.1" \
  ipv4.ignore-auto-dns yes
nmcli con up "Wired connection 1"
```
> Note: AdGuard is reachable from the Spectrum subnet (192.168.1.x) only through routing via
> the Archer. If the Archer is the only path to 192.168.12.244, this may not resolve when
> enp4s0 is the active route. Test before committing.

**Verify (from laptop):**
```bash
# Should return an IP, not SERVFAIL:
dig +short jellyfin.tiamat.local

# Confirm which DNS server answered:
resolvectl status | grep "DNS Servers"
```

---

## Step 8 — Bahamut itself (192.168.12.244, DietPi)

**Do NOT point Bahamut at itself** (`127.0.0.1` or `192.168.12.244`).
AdGuard manages its own upstream resolvers. Bahamut uses those directly.

Verify Bahamut's own upstream DNS in AdGuard UI:
`http://192.168.12.244:8081` → Settings → DNS Settings → Upstream DNS servers.
Recommended upstreams: `1.1.1.1` and `8.8.8.8`.

---

## Verification

Run these from any device after changing its DNS:

```bash
# 1. Confirm AdGuard is reachable and responding:
dig +short google.com @192.168.12.244
# Expected: a real IP, e.g. 142.250.x.x

# 2. Confirm local wildcard rewrite resolves:
dig +short jellyfin.tiamat.local
# Expected: 192.168.12.30

dig +short riven.mediastack.lan
# Expected: 192.168.12.30

# 3. Confirm the device is actually using AdGuard (not ISP DNS):
dig +short whoami.akamai.net
# Then check AdGuard query log at http://192.168.12.244:8081
# -> Query Log should show the request from your device's IP
```

**AdGuard query log** is the authoritative check: `http://192.168.12.244:8081` → Query Log.
Filter by client IP to confirm the device's queries are arriving.

---

## OpenWrt/UE300 — Current State (2026-07-11)

The UE300 is installed and `vmbr2` is operational. OpenWrt VM-100's `br-lan`
bridges `eth1` (vmbr1, virtual) + `eth2` (vmbr2/UE300 physical). The UE300 RJ45
connects to the Archer switch, giving OpenWrt a physical LAN port.

**Current split:**
- Archer handles DHCP/DNS for `192.168.12.0/24` → pushes AdGuard to all clients
- OpenWrt handles routing for `10.10.0.0/24` (virtual internal only for now)

**To hand full DHCP/DNS control to OpenWrt:**
1. Configure OpenWrt DHCP on `br-lan` for `192.168.12.0/24` (change its LAN IP to `192.168.12.1` or keep Archer as upstream)
2. Disable Archer DHCP pool at `http://192.168.12.1` → Advanced → Network → DHCP Server
3. OpenWrt will then hand out `192.168.12.244` as DNS via its DHCP options (set in Step 5 above)
4. Add firewall rules on OpenWrt to block DNS port 53 to any server except `192.168.12.244`

At that point this per-device guide becomes fallback-only.
