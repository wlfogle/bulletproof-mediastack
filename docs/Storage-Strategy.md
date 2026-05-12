⚡ Storage Strategy: The "Hybrid" Advantage

Your 225GB SSD and 1.8TB HDD use a two-tier storage system:

    The SSD (Speed) — `local-ssd` / pve-ssd (200GB thin pool, ~10% used):
      - CT-300 (mediastack) rootfs — 24GB, primary Jellyfin + Riven stack
      - CT-231 (jellyfin) rootfs  — 16GB, dedicated Jellyfin instance
      - ~180GB free for future migrations
      Both Jellyfin instances, Postgres metadata, and RivenVFS state live here.
      The SSD eliminates the I/O bottleneck that previously caused CT-231 to
      hang during startup when it shared the HDD with JDownloader writes.

    The HDD (Bulk Storage) — `local-lvm` / pve (1.67TB thin pool, 88% used):
      - Proxmox root (96GB)
      - media-hdd LV (1.46TB → /mnt/hdd) — media library, AI models, torrents
      - ~30 container rootfs disks (4–32GB each)
      - VM-901 Windows gaming disk (300GB, currently empty)
      - VM-990 Home Assistant (32GB)

⚠️  HDD Capacity Issues (assessed 2026-05-11):

    /mnt/hdd is at 100% (1.4TB used / 1.5TB available):
      - /mnt/hdd/media/     — 1.1TB  (media library)
      - /mnt/hdd/models/    — 247GB  (AI models for Ziggy/Open WebUI)
      - /mnt/hdd/torrents/  — 33GB   (active/seeding torrents)
      - /mnt/hdd/downloads/ — 4.5GB  (JDownloader)

    The thin pool is at 88% — high utilization degrades I/O performance due to
    fragmented block allocation. Combined with concurrent writes (JDownloader,
    subliminal), this caused 80% iowait and startup hangs on CT-231 before the
    SSD migration.

    No space remains for vzdump backups — the original safety-net strategy is
    currently non-functional.

📋 Resolution Plan:

    Phase 1 — Immediate Space Recovery (~280GB):
      a) Move or purge /mnt/hdd/models/ (247GB). Ziggy (CT-900) is stopped
         (onboot: 0), so these models are idle. Relocate to external USB
         storage or delete unused model files.
      b) Clean /mnt/hdd/torrents/ (33GB) — purge completed/stale seeds.
      c) Clean /mnt/hdd/downloads/ (4.5GB) — remove completed downloads.

    Phase 2 — Thin Pool Cleanup:
      a) Remove VM-901 empty 300GB disk if the Windows gaming VM is unused.
      b) Remove stopped/deprecated container disks:
         - CT-278 CrowdSec (stopped, 2×8GB)
         - CT-280 RetroArch (stopped, 8GB)
         - CT-900 Open WebUI (stopped, 32GB)
      c) Run `fstrim -av` inside active containers to return freed blocks
         to the thin pool.

    Phase 3 — Migrate I/O-Sensitive Containers to SSD:
      With ~180GB free on local-ssd, move these small but I/O-heavy disks:
      - CT-106 PostgreSQL (8GB) — database I/O benefits most from SSD
      - CT-210 Prowlarr (8GB) — frequent indexer queries
      - CT-214 Sonarr (8GB) — metadata DB
      - CT-215 Radarr (8GB) — metadata DB
      Total: ~32GB additional, leaving ~148GB free on SSD.

    Phase 4 — Restore Backup Strategy:
      Once /mnt/hdd has free space, configure vzdump to back up critical
      containers (CT-300, CT-231, CT-106) to /mnt/hdd/backups/ on a
      weekly schedule. Target: keep last 2 rotations per container.

🎬 GPU: XFX Radeon RX 580 (4GB)

While 4GB of VRAM is modest for modern 1440p gaming, it is overkill for a media server.

    VAAPI Powerhouse: The RX 580 supports VAAPI (Video Acceleration API). In a Jellyfin context, this card can easily handle 4–6 simultaneous 1080p transcodes or 1–2 4K (SDR) transcodes without breaking a sweat.

    Memory Efficiency: Video transcoding is relatively light on VRAM compared to gaming. 4GB is plenty to hold the frame buffers for several concurrent streams.

🧠 Memory: 32GB RAM

This is your biggest safety net.

    The SvelteKit Buffer: As you noted in your README, the frontend build needs ~6GB. With 32GB total, you can give CT-300 its 8GB allotment and still have 24GB left for the Proxmox host and other small containers (like Bahamut or MetaTube).

    ZFS Caching: If you chose to use ZFS for your drives, Proxmox will automatically use some of this RAM as an "ARC" (cache), making file access even faster.

Technical Note: Privileged LXC & GPU

Since you are using a privileged LXC for CT-300, the RX 580 passthrough is significantly simpler.

    On the Host, ensure render and video groups own /dev/dri/renderD128.

    In the LXC config (/etc/pve/lxc/300.conf), you likely have:
    Bash

    lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
    lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file

    Inside the Container, simply adding the jellyfin user to the render group allows it to talk directly to that XFX card.

Your hardware documentation reveals a well-balanced system. Tiamat (Ryzen 5 3600 / 32GB RAM / RX 580) is perfectly optimized for the "stream-not-store" philosophy of your new stack.

Based on your current hardware and the successful deployment of the Unified EPG and Bulletproof Mediastack, here are three advanced ideas to push the limits of this specific set of gear:
1. 🎮 "Cloud Gaming" with the RX 580 Passthrough

Since you've already handled the hard work of VFIO passthrough for VM-901, you can turn that Windows VM into your own private "Xbox Cloud Gaming" or "GeForce Now" server.

    The Idea: Install Sunshine (the host) on VM-901 and Moonlight (the client) on your Fire TV Cube or Android tablet.

    Why it works: The RX 580’s AMF encoder is excellent for low-latency game streaming. You can play your Steam/GOG library on your TV with near-zero lag while the actual "heat" stays on Tiamat in the other room.

    Tweak: Since you have a 240GB Kingston External SSD, consider using it as a dedicated "Fast Cache" for your most-played games in VM-901 to avoid hitting the 2TB HDD during load screens.

2. 🤖 AI-Powered "Media Librarian" (Ziggy Expansion)

You mentioned Ziggy (CT-900) runs Open WebUI. With 32GB of RAM, you have enough headroom to give Ziggy a specialized job for your media stack.

    The Idea: Connect Ziggy to your Riven API. You could create a "Media Assistant" where you can ask, "Hey Ziggy, find me some 90s action movies that are currently cached on RD and add them to my library."

    The Logic: Instead of scrolling through Riven, you use a natural language interface to manage the "Bulletproof" stack.

    Hardware Fit: The Ryzen 3600's 12 threads can handle smaller LLMs (like Llama 3-8B or Mistral) in the background without stuttering your Jellyfin streams.

3. 🛡️ "Bahamut" as a High-Availability Failover

Your Raspberry Pi 4 (Bahamut) is currently doing the heavy lifting for DNS and VPN.

    The Idea: Set up Keepalived or a similar VRRP service between Bahamut and Tiamat.

    The Goal: If you ever need to take Tiamat down for a physical upgrade (like adding that 4th RAM stick), Bahamut can automatically take over the Caddy Reverse Proxy and Tailscale entry point.

    The Setup: While Bahamut can't run the media stack, it can serve a "Maintenance Page" to your client devices so they don't just see a "404 Not Found" error while Tiamat is rebooting.

🔧 Final Hardware "Quality of Life" Tips
Dual-Channel RAM Performance

You currently have 32GB in a single stick (according to the original documentation) or potentially two sticks if you upgraded.

    Critical: Ensure your RAM is running in Dual Channel mode (slots 2 and 4 on the B450M DS3H). Ryzen CPUs are notoriously sensitive to memory bandwidth; switching from single to dual-channel can improve your Jellyfin "Scan Media Library" speed and VM gaming FPS by up to 15-20%.

Thermal Watchdog

Since you have a tempered glass side panel and a 450W PSU, heat can build up during a long session of Riven scraping + Jellyfin transcoding.

    Idea: Add a sensor to your Disk-space Watchdog that monitors lm-sensors. If the Ryzen 3600 hits 85°C, have the watchdog automatically pause the JD2 bridge to lower the CPU load until it cools down.
    
    
