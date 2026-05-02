# bulletproof-mediastack

**Post-*arr media pipeline.** One privileged Proxmox LXC, one deploy script, one
request UI, one player. From "search a show" to "playing in Jellyfin" in
~30–60 seconds, with no torrent client and no local media disk.

Forked from [`wlfogle/homelab-media-stack`](https://github.com/wlfogle/homelab-media-stack)
after 11 deployment attempts of the *arr stack failed on a single 1.8 TB HDD.

## Architecture

```text
                           CT-300 (Debian 12, privileged LXC)
                  ┌────────────────────────────────────────────────────┐
   user request → │  Riven frontend (SvelteKit)  :3000                 │
                  │  Riven backend  (Python+RivenVFS)  :8080  → /mount │
                  │      ↑ scrapes Torrentio, talks to Real-Debrid     │
                  │      ↓ FUSE-mounts your RD library at /mount       │
                  │  Jellyfin :8096   ←── reads /mount, real-time sync │
                  │  PostgreSQL 15, Redis, Caddy (TLS), CrowdSec       │
                  └────────────────────────────────────────────────────┘
                      Files live at Real-Debrid. Disk space used: 0.
```

The previous stack used `zurg` + `rclone` to expose Real-Debrid as a WebDAV
mount; **Riven now ships its own FUSE VFS (RivenVFS)** and replaces both. No
`zurg`, no `rclone`, no symlink dance.

## How it works

1. You add a show or movie in **Riven** (port 3000).
2. Riven scrapes Torrentio for Real-Debrid-cached torrents.
3. Riven adds the magnet to your RD library via the RD API.
4. **RivenVFS** (built into the backend) FUSE-mounts the RD library at
   `/mount/{movies,shows}` — files appear instantly, streamed on demand from
   RD's CDN.
5. **Jellyfin** real-time monitor sees the new file at `/mount` and the title
   becomes playable within seconds.

Total time from "add" to "play": 30–60 seconds. Local disk used: 0 bytes.

## Deploy

On the Proxmox host as root:

```bash
git clone https://github.com/wlfogle/bulletproof-mediastack.git /opt/bulletproof-mediastack
cd /opt/bulletproof-mediastack
cp .env.example .env
# Paste your Real-Debrid token from https://real-debrid.com/apitoken
nano .env
bash scripts/deploy.sh
```

The script is idempotent. Rerun it anytime; it reuses CT-300 unless you set
`FORCE_RECREATE=1`.

## What `scripts/deploy.sh` actually does

The script is a single ~780-line, end-to-end native deploy that:

1. **Preflight (host)** — validates the RD token against
   `https://api.real-debrid.com/rest/1.0/user`, verifies reachability of every
   APT/repo URL it will touch, checks host RAM, confirms the target Proxmox
   storage exists.
2. **Creates CT-300** — privileged Debian 12 LXC with `nesting`, `keyctl`,
   `fuse` features, `apparmor:unconfined`, plus `/dev/fuse`, `/dev/dri`,
   `/dev/net/tun` bind-mounts.
3. **Bootstraps the CT** — installs Postgres 15, Redis, Jellyfin (with VAAPI
   group setup against the host's actual render gid), Caddy, CrowdSec, Node 24
   from NodeSource, pinned `pnpm@10.28.0`, pinned `uv` (with fallback installer),
   `libsqlite3-dev` for `better-sqlite3`, locales (`en_US.UTF-8` + `C.UTF-8`),
   and tzdata.
4. **Configures PostgreSQL** — sets the `postgres` password, creates the
   `riven` DB, ensures `pg_hba.conf` allows `scram-sha-256` over loopback,
   then *proves* TCP auth works with `PGPASSWORD=postgres psql -h 127.0.0.1`
   before continuing.
5. **Builds Riven backend** — clones `rivenmedia/riven`, installs Python 3.13
   via `uv`, runs `uv sync --no-dev --frozen`, applies `setcap cap_sys_admin+ep`
   to the venv Python (so RivenVFS can mount FUSE without running as root),
   and creates `/mount` + `/var/cache/riven`.
6. **Builds Riven frontend** — clones `rivenmedia/riven-frontend`, runs
   `pnpm install && pnpm run build && pnpm prune --prod` with
   `NODE_OPTIONS=--max-old-space-size=6144` (Vite/SvelteKit OOMs at the V8
   default), then verifies `build/index.js` exists before enabling the unit.
7. **Writes systemd units** for `riven` and `riven-frontend` with the full env
   from upstream's `.env.example` files: `API_KEY`, `RIVEN_DATABASE_HOST`,
   `RIVEN_FILESYSTEM_*`, `BACKEND_URL`, `BACKEND_API_KEY`, `DATABASE_URL`,
   `AUTH_SECRET`, `ORIGIN`, `PROTOCOL_HEADER`, `HOST_HEADER`. Persistent
   secrets live on the Proxmox host at `/etc/bulletproof-mediastack-api-key`
   and `/etc/bulletproof-mediastack-auth-secret`.
8. **Configures Jellyfin** — enables real-time monitor on every library it
   sees, restarts Jellyfin so the change takes effect.
9. **Configures Caddy** — writes the Caddyfile and runs
   `caddy validate --adapter caddyfile` as a hard gate before
   `systemctl enable --now caddy`. Failure aborts the whole deploy.
10. **Configures CrowdSec** — journal + Caddy access log acquisitions, with
    Linux/SSHD/Caddy collections.
11. **Verifies everything** — for each of the 8 services, waits up to 60 s for
    `systemctl is-active`, then runs HTTP probes against the Riven backend,
    frontend, Jellyfin, and Caddy. Failure prints the journal tail and exits
    non-zero.

## Hardening summary

The script was designed against a list of every failure mode actually
encountered or known-likely on this hardware:

- RD token validated upfront (no 5-minute walk into a 401 later)
- APT/GPG operations retried with backoff
- `uv` + `pnpm` pinned, fallback installer for `uv`
- `better-sqlite3` native build covered with `libsqlite3-dev`
- Render gid auto-detected from `/dev/dri/renderD128`
- RivenVFS cache pinned to `/var/cache/riven` (never the 64 MB LXC `/dev/shm`)
- Node heap raised to 6 GB for the Vite build (was OOMing at the V8 default)
- Frontend env complete: `BACKEND_API_KEY`, `AUTH_SECRET`, `DATABASE_URL`,
  proxy headers — without these the SvelteKit/better-auth runtime fails
- `caddy validate` is a hard gate before enable
- HTTP probes per service before declaring success
- Persistent secrets generated once and reused on rerun

## Hardware target

- **Tiamat** — Proxmox VE host, AMD Ryzen 5 3600, 32 GB RAM, RX 580 (VAAPI),
  `local-ssd` thin pool on a dedicated SSD (the 1.8 TB HDD is no longer in
  the data path; it only holds backups).
- **Bahamut** — Pi 4 (DNS / VPN / Vaultwarden), untouched.

CT-300 sizing: 6 cores, 8 GB RAM, 24 GB rootfs on `local-ssd`.

## Requirements

- Proxmox VE host with `pct`
- Real-Debrid subscription (or AllDebrid / Premiumize — the deploy defaults
  to RD; trivial to swap by editing the unit env)
- One privileged LXC's worth of resources (~8 GB RAM, 6 cores, 24 GB rootfs)
- Internet ≥50 Mbps for streaming (RivenVFS caches the active stream segment)

## Why this works when *arr didn't

The *arr stack on this hardware always failed the same way: a single 1.8 TB HDD
serving 14 LXC rootfs partitions, multiple SQLite WALs, qBit incomplete writes,
and Jellyfin metadata scans **at the same time**. Every backup, every update,
every stalled torrent caused IO storms that cascaded into "database is locked"
errors across the *arr suite.

This stack moves storage off local disk entirely (Real-Debrid is the storage)
and collapses 14 services into 4. The remaining services don't compete: the
Riven backend serves RD via FUSE, Postgres holds metadata, Jellyfin reads
files. No service writes large blobs to local disk except the RivenVFS cache
(capped at 1 GB). The IO storm cannot happen.

## Troubleshooting

```bash
# All services in CT-300:
pct exec 300 -- systemctl status postgresql redis-server jellyfin caddy crowdsec riven riven-frontend

# Live logs:
pct exec 300 -- journalctl -fu riven
pct exec 300 -- journalctl -fu riven-frontend
pct exec 300 -- journalctl -fu jellyfin

# Verify RivenVFS mount:
pct exec 300 -- ls /mount

# Re-run deploy idempotently (script will reuse CT-300):
bash /opt/bulletproof-mediastack/scripts/deploy.sh

# Wipe and rebuild from scratch:
FORCE_RECREATE=1 STORAGE=local-ssd bash /opt/bulletproof-mediastack/scripts/deploy.sh
```

## Related

- Riven: https://github.com/rivenmedia/riven
- Riven frontend: https://github.com/rivenmedia/riven-frontend
- Jellyfin: https://jellyfin.org
- Upstream (the *arr stack we're replacing): [`wlfogle/homelab-media-stack`](https://github.com/wlfogle/homelab-media-stack)
