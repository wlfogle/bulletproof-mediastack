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

## Wireless → Wireless Settings

| Setting | Value | Reason |
|---|---|---|
| Smart Connect | Enabled | Band-steers Fire TVs / phones to 5 GHz automatically |
| TWT | Enabled | Extends battery life on phones |
| OFDMA + MU-MIMO | Enabled | Concurrent Fire TVs + phones + laptop streaming |
| Transmit Power | High | Full house coverage |
| Channel Width | Auto | Router selects optimally per band |
| Channel | Auto | Avoids interference |
| Security | WPA2/WPA3 Personal | Best compatibility + security |

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

| Setting | Value | Reason |
|---|---|---|
| WMM | Enabled | Prioritises Jellyfin/streaming packets |
| AP Isolation | **Disabled** | Jellyfin DLNA, HDHomeRun, HABridge Alexa discovery all require LAN device-to-device communication |
| Airtime Fairness | Enabled | Prevents slower devices hogging airtime |
| Zero Wait DFS | Enabled | Eliminates channel-change lag on 5 GHz |
| Beacon Interval | `100` ms | Default — fine |
| RTS Threshold | `2346` | Default — fine |
| DTIM Interval | `1` | Best responsiveness for streaming |
| Group Key Update Period | `86400` | Reduces unnecessary re-auth on Fire TVs |

---

## Advanced → NAT Forwarding → Virtual Servers

| Service | External Port | Protocol | Internal IP | Internal Port |
|---|---|---|---|---|
| WireGuard VPN | `51820` | UDP | `192.168.12.244` | `51820` |

> Required for remote VPN access now that Archer is the edge router (not T-Mobile).

---

## Advanced → NAT Forwarding → UPnP

| Setting | Value | Reason |
|---|---|---|
| UPnP | **Enabled** | HABridge (CT-501) requires SSDP/UPnP on port 1900/udp for Alexa device discovery |

---

## Advanced → Security → Firewall

| Setting | Value |
|---|---|
| SPI Firewall | Enabled |
| VPN Passthrough (IPSec) | Enabled |
| VPN Passthrough (PPTP) | Enabled |
| VPN Passthrough (L2TP) | Enabled |

---

## Advanced → Security → ALG

| Setting | Value | Reason |
|---|---|---|
| SIP ALG | **Disabled** | Causes WireGuard handshake failures and VoIP issues |
| FTP ALG | Enabled | Default — fine |
| TFTP ALG | Enabled | Default — fine |
| H323 ALG | Enabled | Default — fine |

---

## Advanced → Security → Device Isolation

Add the unidentified Shenzhen IoT device. It retains internet access but cannot reach Tiamat, Bahamut, or CT-300.

| MAC | Last IP | Vendor | Action |
|---|---|---|---|
| `5C:E7:53:45:EA:3E` | 192.168.12.140 | Shenzhen Intellirocks | Isolate |

---

## Advanced → Security → Access Control

Leave in default (no block list) unless a device needs to be permanently banned. Device Isolation is sufficient for the unknown IoT device.

---

## Advanced → System → Administration

| Setting | Value | Reason |
|---|---|---|
| Local Management via HTTPS | Enabled | Secure LAN admin |
| Remote Management | **Disabled** | WireGuard provides remote access — no need to expose router admin to WAN |

---

## Advanced → HomeShield → QoS

Enable QoS and set **High Priority** for media-critical hosts:

| Device | IP / MAC | Role |
|---|---|---|
| Tiamat | `192.168.12.242` | Proxmox / Jellyfin media server |
| CT-300 mediastack | `192.168.12.30` | Caddy / Jellyfin / Riven |
| Fire TV — living room | `78:A0:3F:2D:B9:E0` | Primary Jellyfin client |
| Fire TV — bedroom | `D8:E7:43:20:7C:64` | Secondary Jellyfin client |

---

## Advanced → Network → DHCP Server → Address Reservation

Bind all static infrastructure so IPs survive reboots and DHCP pool changes:

| Hostname | MAC | IP |
|---|---|---|
| tiamat | `B4:2E:99:AA:CF:06` | `192.168.12.242` |
| bahamut | `88:A2:9E:85:CD:E6` | `192.168.12.244` |
| mediastack (CT-300) | `BC:24:11:E3:7C:DB` | `192.168.12.30` |
| homeassistant (VM-990) | `02:88:F9:77:28:E2` | `192.168.12.123` |
| habridge (CT-501) | `BC:24:11:AB:A3:2D` | `192.168.12.251` |
| alexa-media-bridge (CT-200) | `BC:24:11:30:1C:C2` | `192.168.12.201` |
| hdhr (HDHomeRun) | `00:18:DD:04:8E:EE` | `192.168.12.215` |
| printer (Epson ET-2850) | `68:55:D4:34:0E:C8` | `192.168.12.198` |

> Devices with Proxmox/DietPi static config hold their IPs independently; reservations here act as a safety net.

---

## Verified Performance

| Host | Download | Upload | Jitter |
|---|---|---|---|
| Laptop (direct Spectrum) | 923 Mbps | 916 Mbps | — |
| Bahamut (via Archer) | 497 Mbps | 202 Mbps | 1.5 ms |

> Bahamut upload ceiling (~200 Mbps) is the Pi 4's internal USB-to-Ethernet bus limit, not the Archer.
