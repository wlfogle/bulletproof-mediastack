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
## Recommended Models for 12GB VRAM
- `llama3.1:8b`
- `qwen2.5:7b`
- `mistral:7b`
Use quantized variants for better performance.
## CT-102: n8n — Self-Healing Code Fixer
n8n (v2.8.4) runs in CT-102 (`192.168.12.102:5678`) managed by PM2.

### Workflow
Active workflow: **Self-Healing Code Fixer** (ID: `7ViGS0znZtjIAtlE`)
- Webhook endpoint: `http://192.168.12.102:5678/webhook/fix-code`
- Accepts POST with `{"code", "language", "error"}`, returns `{"fixedCode", "explanation"}`
- Auto-activates on n8n startup

### VS Code Extension
Extension: `your-publisher-name.self-healing-assistant` v0.1.0

Settings (`~/.config/Code/User/settings.json`):
```json
{
    "selfHealing.n8nWebhookUrl": "http://192.168.12.102:5678/webhook/fix-code",
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
ssh root@192.168.12.242 "pct exec 102 -- pm2 status"
ssh root@192.168.12.242 "pct exec 102 -- pm2 restart n8n --update-env"
ssh root@192.168.12.242 "pct exec 102 -- pm2 logs n8n --nostream --lines 20"
```

### Credentials
n8n owner: `loufogle@gmail.com` (password in Opera GX password manager for `192.168.12.102:5678`)

## Notes
- If laptop IP changes, update `OLLAMA_HOST`.
- Keep model cache on fast storage.
- CT-102 was recreated 2026-05-19; its Ollama URL must match the current laptop IP.
