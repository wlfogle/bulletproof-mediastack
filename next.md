# open
how get /mnt/hdd/media/recordings/Series recognized as tv shows and identified and scraped in jellyfin

the spotify playlists won't play either

# done
~~the unified guide is only showing OTA, and the identify function in jellyfin no longer produces results~~
  - fixed: all sources live (OTA 16491, IPTV 5089, SVOD 200, Library 50)
  - Jellyfin guide now uses /data/streaming/unified.xml (OTA + IPTV merged)
  - cell clicks work (Jellyfin #/details deep-links, Riven /explore?query=)

~~configure homarr for our stack~~
  - Homarr running at http://192.168.12.30:7575 (CT-300 native)
  - 16 apps across Media Stack / Automation / Infrastructure / Laptop
  - monitoring via Cockpit (:9090) + Pulse (:7655)
