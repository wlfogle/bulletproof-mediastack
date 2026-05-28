# Voice Control — "Star Trek Computer" Mode

Control your entire Tiamat homelab with voice commands via Alexa and Home Assistant Assist backed by local Ollama AI. No cloud subscription required.

---

## Architecture

```
You speak
    │
    ├── Fire TV (Living Room / Bedroom) ──────────────────────┐
    │       Alexa built-in                                    │ Smart Home skill
    │       UPnP/SSDP discovery (LAN)                        │ (optional cloud)
    │       ▼                                                 │
    │   CT-501 HABridge (192.168.12.251:80)  ◄───────────────┘
    │   Java Hue emulator
    │       │ HTTP POST to HA REST API
    │       ▼
    └── VM-990 Home Assistant (192.168.12.123:8123)
                │
          ┌─────┴──────────────────┐
          ▼                        ▼
    Phone (HA Companion app)   Services via REST
    HA Assist voice control    Jellyfin, Sonarr, Radarr
                               Ollama (laptop :11434)
```

**Two voice paths:**
1. **Fire TV Alexa → HABridge → HA** — "Alexa, turn on movie night" (no subscription, LAN-local)
2. **Phone → HA Assist + Ollama** — "Computer, status report" via HA Companion app (fully local AI)

---

## CT-501 HABridge Setup

HABridge is a Java app that emulates a Philips Hue bridge, so Alexa discovers your HA scripts as fake Hue lights — no Nabu Casa needed.

### Create the LXC

```bash
# On Tiamat Proxmox (192.168.12.242)
pct create 501 /var/lib/vz/template/cache/debian-12-standard_*.tar.zst \
  --hostname habridge \
  --memory 512 \
  --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.12.251/24,gw=192.168.12.1 \ # Already created
  --storage local-lvm \
  --rootfs local-lvm:4 \
  --unprivileged 1 \
  --start 1

pct exec 501 -- bash -c "apt-get update && apt-get install -y openjdk-17-jre-headless curl"
```

### Install HABridge

```bash
pct exec 501 -- bash -c "
  mkdir -p /opt/habridge
  cd /opt/habridge
  curl -L https://github.com/bwssytems/ha-bridge/releases/latest/download/ha-bridge.jar \
    -o ha-bridge.jar
"
```

### Configure HABridge

```bash
# Create config
pct exec 501 -- bash -c "cat > /opt/habridge/config.json <<'EOF'
{
  "upnpConfigAddress": "192.168.12.251",
  "serverPort": 80,
  "upnpPort": 1900
}
EOF"
```

### Systemd service

```bash
pct exec 501 -- bash -c "cat > /etc/systemd/system/habridge.service <<'EOF'
[Unit]
Description=HABridge — Alexa Hue Emulation
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/habridge
ExecStart=/usr/bin/java -jar -Dconfig.file=/opt/habridge/data/habridge.config /opt/habridge/ha-bridge.jar
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now habridge"
```

### Map HA scripts to fake Hue devices

**9 devices are already configured in habridge** (added 2026-05-28 via REST API).
They all point to `http://192.168.12.123:8123` with `Authorization: Bearer REPLACE_WITH_HA_TOKEN`.

**After you have a HA long-lived token, update each device:**
1. Open `http://192.168.12.251` (HABridge web UI) or `http://habridge.tiamat.local`
2. Edit each device → replace `REPLACE_WITH_HA_TOKEN` with your real token

**Or use the REST API to update in bulk** (see `scripts/update-habridge-token.sh`).

**Get token:** HA → Profile → Long-Lived Access Tokens → Create Token
(`http://192.168.12.123:8123/profile`)

| Device Name | HA Script | Status |
|-------------|-----------|--------|
| Movie Night | `script.movie_night` | ✅ configured, needs token |
| System Status | `script.system_status` | ✅ configured, needs token |
| AI Status | `script.ai_status` | ✅ configured, needs token |
| Download Status | `script.download_status` | ✅ configured, needs token |
| Pause All Media | `script.pause_all_media` | ✅ configured, needs token |
| Media Scan | `script.media_scan` | ✅ configured, needs token |
| Morning Routine | `script.morning_routine` | ✅ configured, needs token |
| Evening Routine | `script.evening_routine` | ✅ configured, needs token |
| Computer Report | `script.computer_report` | ✅ configured, needs token |

### Alexa discovery (Fire TV)

1. On your Fire TV: **Settings → Alexa → Smart Home Devices → Discover Devices**
   OR say **"Alexa, discover my devices"** to your Fire TV
2. Wait 20–45 seconds — HABridge responds to UPnP/SSDP on LAN
3. All 9 devices appear as lights in Alexa
4. Optionally manage via the Alexa app on your phone

---

## Alexa Voice Commands

Once discovered, say:

| Say | What happens |
|-----|-------------|
| "Alexa, turn on **movie night**" | Checks Jellyfin + Plex, sends status to HA |
| "Alexa, turn on **system status**" | Full Tiamat systems report |
| "Alexa, turn on **AI status**" | Checks Ollama on laptop |
| "Alexa, turn on **download status**" | Sonarr + Radarr queue summary |
| "Alexa, turn on **pause all media**" | Pauses all active Jellyfin streams |
| "Alexa, turn on **media scan**" | Triggers Jellyfin + arr library refresh |
| "Alexa, turn on **morning routine**" | Morning briefing |
| "Alexa, turn on **computer report**" | Full diagnostic across all services |

### Alexa Routines (say it naturally)

In the Alexa app on your phone (or Fire TV settings), create routines:

| When you say | Action |
|-------------|--------|
| "Computer, status" | Activate "system status" |
| "Computer, movie time" | Activate "movie night" |
| "Computer, what's downloading" | Activate "download status" |
| "Computer, all systems report" | Activate "computer report" |

---

## HA Assist — Local AI with Ollama

For fully local, AI-powered voice control with natural language:

### Setup

1. **HA** → Settings → Voice Assistants → **Add Assistant**
2. Name: `Tiamat Computer`
3. Language: English
4. Conversation agent: **Ollama** (add via Settings → Integrations → Ollama first)
   - Host: `192.168.12.172`
   - Port: `11434`
   - Model: `llama3.1:8b`
5. Wake word: **"Computer"** — use HA Companion app on your phone as the mic device

### Available intents (from intent_script.yaml)

| Say "Computer, ..." | Intent | Response |
|--------------------|--------|----------|
| "status" / "all systems" | `ComputerStatus` | Live status of all services |
| "movie night" | `ComputerMovieNight` | Jellyfin check + stream count |
| "what's downloading" | `ComputerDownloads` | Sonarr + Radarr queue |
| "AI status" | `ComputerAI` | Ollama version + endpoint |
| "pause" / "stop everything" | `ComputerPause` | Pauses all media players |
| "scan library" | `ComputerScan` | Triggers library refresh |
| "good morning" | `ComputerMorning` | Morning briefing |
| "full report" | `ComputerReport` | Complete system diagnostic |

### HA Assist via phone

Install the **Home Assistant** app (Android/iOS) → log in at `http://192.168.12.123:8123` → tap the microphone icon → speak.

---

## Alexa Routines for Star Trek feel

In the Alexa app (More → Routines → +):

**"Engage"** routine:
- Trigger: "Alexa, engage"
- Actions: Activate "movie night" → Say "Tiamat entertainment systems online, Commander"

**"Red Alert"** routine:
- Trigger: "Alexa, red alert"
- Actions: Activate "system status" → Say "Running diagnostics on all Tiamat systems"

**"Stand down"** routine:
- Trigger: "Alexa, stand down"
- Actions: Activate "pause all media" → Say "All systems standing by"

---

## Monitoring

All voice-triggered actions create persistent notifications in HA visible at:
`http://192.168.12.123:8123` → Notifications (bell icon)

Service health dashboard: `http://192.168.12.30:3001` (Uptime Kuma in CT-300)

---

## Troubleshooting

**Alexa can't find devices:**
```bash
# Verify HABridge is running
pct exec 501 -- systemctl status habridge
# Check HABridge web UI
curl http://192.168.12.251
```

**HA script not triggering:**
```bash
# Test HA REST directly
curl -X POST http://192.168.12.123:8123/api/services/script/system_status \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json"
```

**Ollama not responding:**
```bash
curl http://192.168.12.172:11434/api/version
# If offline, check laptop is on and Ollama is running:
# ssh user@192.168.12.172 'systemctl status ollama'
```
