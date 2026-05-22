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
## CT-300: n8n — Self-Healing Code Fixer
n8n (v2.8.4) runs in CT-300 (`192.168.12.30:5678`) managed by PM2 under Node 20.
Its data directory was synchronized from CT-102 on 2026-05-22 and contains 5 workflows, including the active Self-Healing Code Fixer.

### Workflow
Active workflow: **Self-Healing Code Fixer** (ID: `7ViGS0znZtjIAtlE`)
- Webhook endpoint: `http://192.168.12.30:5678/webhook/fix-code`
- Accepts POST with `{"code", "language", "error"}`, returns `{"fixedCode", "explanation"}`
- Auto-activates on n8n startup

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
ssh root@192.168.12.242 "pct exec 300 -- /root/.nvm/versions/node/v20.20.2/bin/pm2 status"
ssh root@192.168.12.242 "pct exec 300 -- /root/.nvm/versions/node/v20.20.2/bin/pm2 restart n8n --update-env"
ssh root@192.168.12.242 "pct exec 300 -- /root/.nvm/versions/node/v20.20.2/bin/pm2 logs n8n --nostream --lines 20"
```

### Credentials
n8n owner: `loufogle@gmail.com` (password in Opera GX password manager; update saved URL to `192.168.12.30:5678`)

## Notes
- If laptop IP changes, update `OLLAMA_HOST`.
- Keep model cache on fast storage.
- CT-102 is no longer the active n8n endpoint. CT-300 is authoritative for n8n.
