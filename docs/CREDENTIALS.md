# Credentials & Access (post-arr)

> Convention: every service that supports its own login uses `servicename / servicename`
> for ease of recall. Master-password / user-chosen secrets (Vaultwarden, Proxmox root)
> are intentionally preserved.
>
> Status legend:
> ✅ already set during deploy ⏳ to set on first login 🔒 preserved (not changed)

## CT-300 — bulletproof-mediastack core (`192.168.12.30`)

| Service | URL | User | Pass | Status |
|---|---|---|---|---|
| Dashboard (tile launcher) | http://192.168.12.30/ | — (no auth) | — | ✅ |
| Riven UI (request) | http://192.168.12.30:3000/ | `riven` | `riven` | ⏳ sign up at first visit (`ENABLE_EMAIL_PASSWORD_SIGNUP=true`) |
| Riven API | http://192.168.12.30:8080/docs | header `Authorization: Bearer <API_KEY>` | — | ✅ key in `/etc/bulletproof-mediastack-api-key` |
| Riven→JD2 bridge | (systemd, no UI) | — | — | ✅ secrets in `/etc/riven-jd2-bridge.env` (CT-300, 0600) |
| JDownloader2 (headless) | https://my.jdownloader.org (remote) | MyJD account | MyJD password | ✅ device `mediastack-jd2`, Xvfb :1, x11vnc loopback :5901 |
| Jellyfin | http://192.168.12.30:8096/ | `jellyfin` | `jellyfin` | ✅ |
| MetaTube backend | http://127.0.0.1:32217/ (loopback only) | — | token `^9NR9[tq03Nwl#3)` | ✅ v1.4.0, `/etc/metatube.env` (0600) |
| Unified Guide | http://192.168.12.30:7700/ · https://guide.mediastack.lan/ | — (no auth) | — | ✅ OTA EPG live; TMDB/YT TV lanes need staging (`docs/UNIFIED-EPG.md`) |
| Homarr Dashboard | http://192.168.12.30:7575/ · https://homarr.mediastack.lan/ | first-run wizard | first-run wizard | ⏳ create admin on first visit |
| Cockpit (system control) | http://192.168.12.30:9090/ | `cockpit` | `cockpit` | ✅ (sudo group) |
| PostgreSQL | 127.0.0.1:5432 (in CT only) | `postgres` | `postgres` | ✅ db=`riven` |
| Redis/Valkey | 127.0.0.1:6379 (in CT only) | — (no auth) | — | bind localhost |
| Caddy (reverse proxy) | :80 / :443 | — | — | local LAN |

### Caddy TLS (internal CA — add to `/etc/hosts` on viewing devices)
```
192.168.12.30 riven.mediastack.lan jellyfin.mediastack.lan cockpit.mediastack.lan guide.mediastack.lan homarr.mediastack.lan threadfin.mediastack.lan
```
- https://riven.mediastack.lan
- https://jellyfin.mediastack.lan
- https://cockpit.mediastack.lan
- https://guide.mediastack.lan      (unified-guide :7700)
- https://homarr.mediastack.lan     (Homarr dashboard :7575)
- https://threadfin.mediastack.lan  (Threadfin :34400 — currently on CT-234)

### Persistent secrets on Tiamat host
| Path | Contents | Mode |
|---|---|---|
| `/etc/bulletproof-mediastack-api-key` | Riven backend `API_KEY` (32 chars) | 0600 |
| `/etc/bulletproof-mediastack-auth-secret` | Riven frontend `AUTH_SECRET` | 0600 |
### Persistent secrets inside CT-300
| Path | Contents | Mode |
|---|---|---|
| `/etc/jellyfin-autoscan.env` | Jellyfin Autoscan API key | 0600 |
| `/etc/riven-jd2-bridge.env` | `RD_USERNAME`, `RD_PASSWORD`, `RD_API_TOKEN`, `MYJD_EMAIL`, `MYJD_PASSWORD`, `MYJD_DEVICE`, `RIVEN_API_BASE` | 0600 |
| `/etc/metatube.env` | `METATUBE_TOKEN=^9NR9[tq03Nwl#3)` (consumed by `metatube.service`) | 0600 |
| `/etc/unified-guide/env` | `UG_TMDB_API_KEY`, `UG_JELLYFIN_TOKEN`, provider list, region, paths | 0600 |
| `/etc/yttv-scraper/env` | YouTube-TV scraper paths (browse.json path, output dir) | 0644 |
| `/opt/homarr.env` | Homarr `SECRET_ENCRYPTION_KEY`, DB driver/url, AUTH_PROVIDERS | 0600 |

## Tiamat host (`192.168.12.242`)

| Service | URL | User | Pass | Status |
|---|---|---|---|---|
| Proxmox VE | https://192.168.12.242:8006/ | `root@pam` | (existing root pw) | 🔒 |
| ProxMenux Monitor | http://192.168.12.242:8008/ | — (no auth) | — | ✅ |
| SSH | `ssh root@192.168.12.242` | `root` | (key auth, ssh-agent) | 🔒 |

## Other CTs / VMs (still running)

| CT | Service | URL | User | Pass | Status |
|---|---|---|---|---|---|
| 100 | wireguard server | `:51820/udp` | (key auth) | — | 🔒 |
| 101 | wg-proxy / TinyProxy | http://192.168.12.101:8888/ | — (no auth) | — | 🔒 |
| 103 | Traefik | http://192.168.12.103:8080/ | — (no auth) | — | 🔒 |
| 104 | Vaultwarden | https://192.168.12.104/ | (your master) | (your master) | 🔒 master-password preserved |
| 105 | Valkey | `:6379` (LAN) | — | — | 🔒 |
| 106 | PostgreSQL | `:5432` | (Authentik internal) | — | 🔒 |
| 107 | Authentik (SSO) | http://192.168.12.107:9000/ | `authentik` | `authentik` | ⏳ change in admin UI to match |
| 110 | Pulse | http://192.168.12.251:7655/ | `pulse` | `pulse` | ⏳ set on first login |
| 234 | Threadfin (IPTV proxy) | http://192.168.12.234:34400/web/ | (admin via web UI) | (admin via web UI) | 🔒 still here pending CT-300 migration (`scripts/migrate-threadfin-to-ct300.sh`) |
| 235 | Dispatcharr (IPTV mgr) | http://192.168.12.235/ | (existing) | (existing) | 🔒 |
| 242 | Jellyseerr | http://192.168.12.242:5055/ | (existing) | (existing) | 🔒 TMDB key sourced from `settings.json` here |
| 200 | alexa-media-bridge | (HA-internal) | — | — | 🔒 |
| 279 | Tailscale | (CLI) | tskey-auth-... | — | 🔒 |
| 990 (VM) | Home Assistant OS | http://192.168.12.123:8123/ | `loufogle` | (your existing pw) | 🔒 |
| 901 (VM) | windows-gaming | console | (Windows local) | — | 🔒 |

## Bahamut Pi (`192.168.12.244`)

| Service | URL | User | Pass | Status |
|---|---|---|---|---|
| AdGuard Home | http://192.168.12.244:8081/ | `adguard` | `adguard` | ⏳ change in Settings → General |
| wg-easy | http://192.168.12.244:51821/ | (master pw hash) | (master pw) | 🔒 |
| Vaultwarden mirror | https://192.168.12.244/ | (your master) | (your master) | 🔒 |
| DietPi Dashboard | http://192.168.12.244:5252/ | (DietPi default) | — | 🔒 |
| TigerVNC | 192.168.12.244:5901 | (DietPi default) | — | 🔒 |

## Test files / smoke-test artifacts

| Item | Path | Notes |
|---|---|---|
| Test movie generator | (deploy-time, ffmpeg in CT-300) | wrote to `/mnt/hdd/media/movies/Bulletproof Test (2026)/` then cleaned up |
| Probe / install scripts | `/tmp/install-*-stage*.sh` | one per deploy stage; can be re-run idempotently |

## API keys reference

| Service | Key location | Usage |
|---|---|---|
| Riven backend `API_KEY` | `/etc/bulletproof-mediastack-api-key` (Tiamat) | sent by Riven frontend, used to drive backend |
| Riven frontend `AUTH_SECRET` | `/etc/bulletproof-mediastack-auth-secret` (Tiamat) | better-auth session signer |
| Jellyfin Autoscan API key | CT-300:`/etc/jellyfin-autoscan.env` | used by `jellyfin-autoscan.service` polling watcher to POST `/Library/Refresh` |
| Real-Debrid token | `/opt/bulletproof-mediastack/.env` (Tiamat) + CT-300:`/etc/riven-jd2-bridge.env` | Riven backend + JD2 bridge both consume |
| Real-Debrid premium expiry | tracked by RD | **2026-05-19** — renew before then |
| MyJDownloader email + password | CT-300:`/etc/riven-jd2-bridge.env` | bridge uses MyJD REST + JD2 uses for device pairing |
| MyJDownloader device name | `mediastack-jd2` (set in env file) | shown on https://my.jdownloader.org once JD2 connects |
| MetaTube backend token | CT-300:`/etc/metatube.env` (`METATUBE_TOKEN=^9NR9[tq03Nwl#3)`) | Jellyfin MetaTube plugin authenticates with this when calling `127.0.0.1:32217/v1/*` |
| Unified Guide TMDB key | CT-300:`/etc/unified-guide/env` (`UG_TMDB_API_KEY`) | discovered from CT-242 Jellyseerr `settings.json`; auto-populated by `install-unified-guide.sh` |
| Unified Guide Jellyfin token | CT-300:`/etc/unified-guide/env` (`UG_JELLYFIN_TOKEN`) | extracted from `/etc/jellyfin-autoscan.env`; library lane on the guide |
| Homarr DB encryption key | CT-300:`/opt/homarr.env` (`SECRET_ENCRYPTION_KEY`, 32-byte hex, auto-generated) | encrypts saved integration creds in Homarr's SQLite DB |

## How to change a credential later

### Riven UI password
After signup, log in → user menu → settings → password.

### Jellyfin password
Login → user menu → Profile → Password.

### Cockpit (`cockpit` user) password
Open Cockpit → top-right user menu → "Authentication" → Change password. Or in a CT-300 shell:
```
pct exec 300 -- bash -c 'echo "cockpit:NEW_PASSWORD" | chpasswd'
```

### Real-Debrid token
Update `/opt/bulletproof-mediastack/.env` on Tiamat → re-run `bash scripts/deploy.sh` (idempotent — picks up new token, rewrites unit, restarts riven).

### Authentik admin / AdGuard / Pulse first-login
Open the URL, log in / sign up. Use the matching `servicename / servicename` value if the UI prompts.

## Quick start

1. Open the **TiamatsStack** android app or browse to `http://192.168.12.30/` → tile dashboard.
2. Tap **Search & Add** → first time: sign up as `riven / riven`. Search a title → click **Request**.
3. Wait ~30–60 s. Tap **Jellyfin** → log in `jellyfin / jellyfin` → the title is in your library.
4. For service control / logs / restart, tap **Cockpit** → log in `cockpit / cockpit`.

## Pop!_OS laptop (`192.168.12.???`)
| Service | URL | User | Pass | Status |
|---|---|---|---|---|
| Waydroid Android container | `waydroid-ui` (terminal) or **"Waydroid"** in app launcher | — (local) | — | ✅ init=GAPPS, lineage-20.0; runs in `cage` nested Wayland |

Waydroid prerequisites (auto-loaded by `waydroid-ui` wrapper):
- kernel modules: `binder_linux` (DKMS via `choff/anbox-modules`), `nft_masq`, `nft_chain_nat`, `nft_compat`, `ip_tables`, `iptable_filter`, `iptable_nat`, `nf_nat`, `nf_conntrack`
- `nftables`, `cage`, `weston` apt packages
- `/etc/modules-load.d/waydroid-iptables.conf` persists modules across reboot
- `/etc/sysctl.d/99-waydroid.conf` keeps `net.ipv4.ip_forward=1`
