how get /mnt/hdd/media/recordings/Series recognized as tv shows and identified and scraped in jellyfin

http://192.168.12.241:7575/ is unreachable.


the spotify playlists won't play either

also, can you integrate my existing services like youtube tv, hbomax, peacock, disney+, netflix into stack? preferably in some kind of guide that spans all available sources.

The core idea: since none of these streaming services expose public APIs, we use TMDB's free API (powered by JustWatch) to discover what's available on each of your services, plus a cross-service "where can I watch this?" search.

Key points:
•  Netflix, Max, Disney+, Peacock get TMDB-powered discover/search (trending content, availability lookup)
•  YouTube TV gets a launcher tile since it's live TV with no content API
•  Scraping YouTube TV's internal EPG

    There's a community project https://github.com/TarheelGrad1998/ha-tv that parses YouTube TV's internal browse.json from the web app, extracting channel names, video IDs, and EPG data from the epgRenderer structure.
    

then fix SPICE in VM-901 AND VM-990


the unified guide is not working, and the identify function in jellyfin no longer produces results, and Lost still has not appeared, and what is url for homarr

2. Spotify playlists playback — untouched; needs diagnosis (likely the Spotify plugin / spotifyd / OAuth token expired).
3. Unified guide lane data — staging TMDB key + Jellyfin token + first browse.json to populate IPTV/SVOD/YTTV/Library lanes.

http://192.168.12.30:8096/web/#/movies?topParentId=f137a2dd21bbc1b99aa5c0f6bf02a805&collectionType=movies why will it not load trailer /home/loufogle/Pictures/2026-05-09_18-52.png

i tried to identify /mnt/hdd/media/movies/01 Teenage Mutant Ninja Turtles - TMNT-1 1990 Eng Subs 720p [H264-mp4]/01 Teenage Mutant Ninja Turtles - TMNT-1 1990 Eng Subs 720p [H264-mp4].mp4 in jellyfin and got these results /home/loufogle/Pictures/2026-05-09_18-56.png

1. 🚀 Post-Deployment: DB "Warming"

Since PostgreSQL 15 is now the brain of your stack (holding Riven’s metadata and your guide’s state), a cold boot of CT-300 might feel sluggish until the cache warms up.

    Improvement: Add a pg_prewarm step to your install-unified-guide.sh. This extension can pre-load your most important tables (like Riven's library and the EPG state) into RAM immediately after the service starts, ensuring the "First Click" on your guide is as fast as the tenth.

2. 🛡️ The "Watchdog" vs. Fragmented Free Space

Your hardlink-aware eviction is brilliant, but standard df commands can be misleading on SSDs due to TRIM and Over-provisioning.

    Improvement: In your disk-space-watchdog.service, consider adding a check for SSD Wear Leveling. Since you're using a 225GB SSD for a "transient" media stack (lots of small writes for logs/metadata/cache), a monthly report on the Percentage Used via smartctl on the host will warn you of hardware failure months before it happens.

3. 🎬 RX 580: The "Tone Mapping" Hurdle

If you start requesting 4K HDR content via Riven, the RX 580 (Polaris architecture) can sometimes struggle with HDR10 to SDR Tone Mapping via VAAPI compared to newer Intel QuickSync or Nvidia chips.

    Suggestion: Ensure you have the non-free firmware and mesa-va-drivers installed inside CT-300. If you notice washed-out colors on your TV when playing 4K files, you may need to enable "OpenCL" inside Jellyfin’s transcoding settings to offload the tone mapping to the GPU’s compute cores.

4. 🔄 YouTube TV: The "Semi-Auto" Cookie Refresh

The browse.json manual step is your biggest point of manual friction.

    Suggestion: You can likely automate the "push" part. On your desktop machine (where you do the export), create a simple one-line alias or script:
    Bash

    # Run this after saving browse.json to your desktop
    scp browse.json tiamat:/tmp/ && ssh tiamat 'pct push 300 /tmp/browse.json /var/lib/yttv-scraper/browse.json && pct exec 300 -- systemctl start yttv-scraper.service'

    Advanced: If you use a browser like Chrome or Edge, there are extensions (like Get-Cookies.txt) that can export cookies to a file. You could sync that file to Tiamat via Syncthing, allowing the scraper to run without you ever opening Dev Tools.

5. 🏗️ The "Atomic" Rollback

Your deploy script is idempotent, which is great, but a failed pnpm build could leave the frontend in a broken state.

    Improvement: Since you are on local-ssd, use LXC Snapshots. At the very start of deploy.sh, run:

Bash

    pct snapshot 300 pre-deploy-$(date +%F)
    ```
    If any of your 11 verification steps fail, you can `pct rollback 300` and be back to a working state in 2 seconds.

---

### One Final Query
Your **SVOD virtual lanes** (Netflix/Max/Disney+) are currently populated via TMDB. Have you considered adding a **"Deep Search"** button to the EPG UI? If a show isn't on an SVOD lane, a single click could fire a search query directly to **Riven**'s `/search` endpoint to see if a cached torrent is available on Real-Debrid.

**How is the "Channel Matching" logic performing? Are the XMLTV names from Threadfin and YouTube TV aligning well, or are you having to do a lot of manual mapping in the Jellyfin dashboard?**
