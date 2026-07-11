# Archer AX55 Pro — Optimal Settings

Admin UI: `http://192.168.12.1`

## Topology

```
Spectrum SAX1V1K (WAN: 74.134.128.100)
  └── Archer AX55 Pro (WAN: 192.168.1.61 / LAN: 192.168.12.1)
        ├── Tiamat    192.168.12.242  (static, Proxmox)
        ├── Bahamut   192.168.12.244  (static, Pi 4 / AdGuard / WireGuard)
        └── Clients   192.168.12.100–200 (DHCP)
```

---

## Advanced → NAT Boost

| Setting | Value |
|---|---|
| NAT Boost | **Enabled** |

> Offloads NAT to hardware chipset. Brings Bahamut from 41 Mbps → 497 Mbps.
> Disables software QoS — acceptable at gigabit speeds.

---

## Advanced → Network → LAN

| Setting | Value |
|---|---|
| IP Address | `192.168.12.1` |
| Subnet Mask | `255.255.255.0` |
| DHCP Server | Enabled |
| IP Pool Start | `192.168.12.100` |
| IP Pool End | `192.168.12.200` |
| DNS 1 | `192.168.12.244` (AdGuard on Bahamut) |
| DNS 2 | `1.1.1.1` |
| Lease Time | `1440` min |

> Static hosts (.242 Tiamat, .244 Bahamut) are outside the DHCP pool.

---

## Advanced → Network → Internet (WAN)

| Setting | Value |
|---|---|
| Connection Type | Dynamic IP (DHCP) |
| MTU | `1500` |
| Get DNS from ISP | Disabled |
| DNS 1 | `192.168.12.244` |
| DNS 2 | `1.1.1.1` |

---

## Advanced → Wireless → 2.4 GHz

| Setting | Value |
|---|---|
| Mode | 802.11b/g/n/ax |
| Channel | Auto |
| Channel Width | 40 MHz |
| Transmit Power | High |
| Beamforming | Enabled |
| MU-MIMO | Enabled |

---

## Advanced → Wireless → 5 GHz

| Setting | Value |
|---|---|
| Mode | 802.11a/n/ac/ax (WiFi 6) |
| Channel | Auto (or 36 / 149 if congested) |
| Channel Width | **160 MHz** |
| Transmit Power | High |
| Beamforming | Enabled |
| MU-MIMO | Enabled |
| Airtime Fairness | Enabled |
| Short Guard Interval | Enabled |
| OFDMA | Enabled |
| Security | WPA2/WPA3 mixed |

> 160 MHz doubles throughput vs 80 MHz for WiFi 6 clients.

---

## Advanced → Wireless → Additional Settings

| Setting | Value |
|---|---|
| Band Steering | Enabled |

---

## Advanced → NAT Forwarding → Virtual Servers

| Service | External Port | Protocol | Internal IP | Internal Port |
|---|---|---|---|---|
| WireGuard VPN | `51820` | UDP | `192.168.12.244` | `51820` |

> Required for remote VPN access now that Archer is the edge router (not T-Mobile).

---

## Advanced → Security → Firewall

| Setting | Value |
|---|---|
| SPI Firewall | Enabled |
| VPN Passthrough (IPSec) | Enabled |
| VPN Passthrough (PPTP) | Enabled |
| VPN Passthrough (L2TP) | Enabled |

---

## Static DHCP Reservations (Optional but Recommended)

| Hostname | MAC | IP |
|---|---|---|
| tiamat | `B4:2E:99:AA:CF:06` | `192.168.12.242` |
| bahamut | `88:A2:9E:85:CD:E6` | `192.168.12.244` |

> Prevents IP conflicts if static config is ever lost.

---

## Verified Performance (post NAT Boost)

| Host | Download | Upload | Jitter |
|---|---|---|---|
| Laptop (direct Spectrum) | 923 Mbps | 916 Mbps | — |
| Bahamut (via Archer) | 497 Mbps | 202 Mbps | 1.5 ms |

> Bahamut upload ceiling (~200 Mbps) is the Pi 4's internal USB-to-Ethernet bus limit, not the Archer.
