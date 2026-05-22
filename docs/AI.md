# AI Services (Laptop RTX 4080 + CT-900)
Architecture:
- Laptop runs Ollama with RTX 4080 acceleration.
- CT-900 runs Open WebUI (frontend) and SearXNG (web search backend).
## Laptop: Ollama
Install and run Ollama listening on LAN:
```bash
curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl enable --now ollama
```
Set host binding for LAN access:
```bash
sudo systemctl edit ollama
```
Drop-in:
```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
```
Restart:
```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```
Verify:
```bash
curl http://127.0.0.1:11434/api/tags
nvidia-smi
```
## CT-900: Open WebUI + SearXNG
`media-stack/docker-compose.yml` includes:
- `open-webui` on port `3000`
- `searxng` on port `8081`
Env values:
```bash
OPENWEBUI_PORT=3000
SEARXNG_PORT=8081
OLLAMA_HOST=http://192.168.12.204:11434
```

> Laptop DHCP reservation is 192.168.12.172 but may be assigned 192.168.12.204 — always verify with `ip addr show enp4s0` before using.
## Open WebUI Configuration
1. Open WebUI admin settings.
2. Confirm Ollama endpoint matches `OLLAMA_HOST`.
3. Enable web search and set SearXNG endpoint.
## Ollama Model Storage
Models are stored on a dedicated second NVMe (`/dev/nvme0n1p2`, 337 GB):
```
/media/loufogle/73cf9511-0af0-4ac4-9d83-ee21eb17ff5d/models/
```
To tell Ollama to use this path:
```bash
# /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment="OLLAMA_MODELS=/media/loufogle/73cf9511-0af0-4ac4-9d83-ee21eb17ff5d/models"
```
As of 2026-05-20 the drive is **89% full (282/337 GB)**. The two largest models
(`llama3.2-vision:90b` 54 GB, `llama3.3:70b` 42 GB) account for 96 GB;
remove them if not actively used to restore headroom.

## Recommended Models for 12GB VRAM
- `llama3.1:8b`
- `qwen2.5:7b`
- `mistral:7b`
Use quantized variants for better performance.
## CT-300: n8n
n8n v2.8.4 runs in CT-300 (`192.168.12.30:5678`) managed by PM2 (`/bin/sh /usr/local/bin/n8n-ct300-start`) under Node 20 via nvm.
Data migrated from CT-102 on 2026-05-22. 5 workflows, 3 active, 2 inactive.

### Active Webhooks

| Workflow | ID | Endpoint | Input | Output |
|---|---|---|---|---|
| Self-Healing Code Fixer | `7ViGS0znZtjIAtlE` | `POST /webhook/fix-code` | `{code, language, error}` | `{fixedCode, explanation}` |
| Smart Notification & Ingestion Alerts | `lCZpfV4kHSZ93k8x` | `POST /webhook/media-ingested` | `{title, event, poster?}` | `{ok, skipped?, message}` |
| Automatic Jellyfin Library Refreshing | `WZzeAao5hFA0kDvp` | `POST /webhook/jellyfin-refresh` | `{libraryId?}` | `{ok, target}` |

### Inactive Workflows
- **Smart Watchlist Ingestion** (`8bluQniJoqSzn7Fc`) — kept disabled; requires Trakt token rotation.
- **Automated Stuck Torrent Purging** (`0QX5pGmpR0UUynoU`) — schedule trigger, runs manually or on demand.

### Architecture Notes (n8n 2.8.4 Task Runner)
n8n 2.8.4 uses an internal JS task runner subprocess for Code nodes. This runner has a **restricted sandbox**:
- `fetch()` — not available (use HTTP Request nodes for HTTP calls)
- `$helpers` — not available in task runner context
- `$env.*` — blocked by default ("access to env vars denied")
- `$vars.*` — **available** (n8n Variables table, use this for secrets)
- `process.env.*` — not available in task runner

All secrets (Jellyfin API key, Real-Debrid token, notification URL, Trakt ID, TMDB key) are stored in the
n8n **Variables** table (viewable at `http://192.168.12.30:5678/variables`) and referenced as `$vars.KEY_NAME`
in workflow nodes. They are also mirrored in `/etc/n8n/media-stack.env` for process-level access.

### Workflow Activation Fix (2026-05-22)
The Jellyfin and Notification workflows failed to activate on CT-102→CT-300 migration because their
`workflow_history` entries had empty (`[]`) nodes, while n8n 2.8.4 activates workflows from history
(keyed by `workflow_entity.activeVersionId`), not directly from `workflow_entity.nodes`.
Fix: populated `workflow_history.nodes` from `workflow_entity.nodes` for both workflows,
then restarted n8n.

### VS Code Extension
Extension: `your-publisher-name.self-healing-assistant` v0.1.0

Settings (`~/.config/Code/User/settings.json`):
```json
{
    "selfHealing.n8nWebhookUrl": "http://192.168.12.30:5678/webhook/fix-code",
    "selfHealing.enableLogging": true,
    "selfHealing.requestTimeout": 120000
}
```

Usage:
- Right-click file → "Fix Entire File with AI" or `Ctrl+Shift+F`
- Select code → "Fix Selected Code with AI" or `Ctrl+Shift+S`

### Desktop Launcher
App launcher entry at `~/.local/share/applications/n8n.desktop` opens the dashboard in the default browser.

### Management
```bash
# Via Proxmox host
ssh root@192.168.12.242 "pct exec 300 -- bash -c 'source /root/.nvm/nvm.sh && pm2 status'"
ssh root@192.168.12.242 "pct exec 300 -- bash -c 'source /root/.nvm/nvm.sh && pm2 restart n8n'"
ssh root@192.168.12.242 "pct exec 300 -- bash -c 'source /root/.nvm/nvm.sh && pm2 logs n8n --nostream --lines 30'"
# Check registered webhooks:
ssh root@192.168.12.242 "pct exec 300 -- sqlite3 /root/.n8n/database.sqlite 'SELECT webhookPath, method FROM webhook_entity'"
```

### Credentials
n8n owner: `loufogle@gmail.com` (password in Opera GX password manager; update saved URL to `192.168.12.30:5678`)

### Secrets / Environment Variables
| Variable | Purpose | Set via |
|---|---|---|
| `JELLYFIN_API_KEY` | Jellyfin library refresh API token | `/etc/n8n/media-stack.env` + n8n Variables |
| `REAL_DEBRID_API_TOKEN` | Real-Debrid API access | `/etc/n8n/media-stack.env` + n8n Variables |
| `N8N_NOTIFICATION_WEBHOOK_URL` | Outbound notification URL (Discord/Gotify/generic) | n8n Variables (empty = notifications skipped) |
| `N8N_NOTIFICATION_KIND` | Payload format: `discord`, `gotify`, `telegram`, `generic` | n8n Variables (default: `generic`) |
| `TRAKT_CLIENT_ID` | Trakt API client ID for watchlist | `/etc/n8n/media-stack.env` + n8n Variables |
| `TMDB_API_KEY` | TMDB metadata | `/etc/n8n/media-stack.env` + n8n Variables (empty) |

## Notes
- If laptop IP changes, update `OLLAMA_HOST`.
- Keep model cache on fast storage.
- CT-102 is no longer the active n8n endpoint. CT-300 is authoritative for n8n.
