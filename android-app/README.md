# TiamatsStack Android App

WebView-based dashboard for the **bulletproof-mediastack** (post-*arr) on Tiamat.
Works on phones, tablets, and Fire TV (LEANBACK_LAUNCHER + D-pad navigation).

## Services

The whole media pipeline now lives in **CT-300** (`192.168.12.30`). The app
shortcuts to:

**Watch:**
- Jellyfin — `http://192.168.12.30:8096`
- Live TV (Jellyfin DVR / IPTV) — `http://192.168.12.30:8096/web/#/livetv.html`

**Search & Add:**
- Riven UI (replaces Jellyseerr + Sonarr/Radarr) — `http://192.168.12.30:3000`

**Tools:**
- Riven API (diagnostics) — `http://192.168.12.30:8080`
- AI Chat (Open WebUI on CT-900 when running) — `http://192.168.12.250:3000`

**Infrastructure:**
- AdGuard Home (Bahamut) — `http://192.168.12.244:3000`
- VPN / wg-easy (Bahamut) — `http://192.168.12.244:51821`
- Vaultwarden (CT-104) — `https://192.168.12.104`
- Authentik (CT-107) — `http://192.168.12.107:9000`

Service URLs are defined in `app/src/main/java/com/tiamat/mediastack/MediaService.kt`.

## Prerequisites

```bash
sudo nala install openjdk-17-jdk android-tools-adb
export ANDROID_HOME=~/Android/Sdk
```

## Build

```bash
# From the android-app/ directory:

# Debug builds (both flavors)
./gradlew assembleDebug

# Single flavor
./gradlew assembleMobileDebug
./gradlew assembleFiretvDebug

# Release
./gradlew assembleRelease
```

APKs output to `app/build/outputs/apk/<flavor>/<buildType>/`.

## Product Flavors

- **mobile** (`.mobile`) — Phone/tablet, portrait grid, LAUNCHER intent
- **firetv** (`.firetv`) — Fire TV / Android TV, 4-column grid, LEANBACK_LAUNCHER intent, D-pad navigation

## Install

### Phone / Tablet
```bash
adb install app/build/outputs/apk/mobile/debug/app-mobile-debug.apk
```

### Fire TV (ADB over network)
1. On Fire TV: **Settings → My Fire TV → Developer Options**
   - Enable **ADB Debugging**
   - Enable **Apps from Unknown Sources**
2. Find Fire TV IP: **Settings → My Fire TV → About → Network**
3. Connect and install:
   ```bash
   adb connect <fire-tv-ip>:5555
   adb install app/build/outputs/apk/firetv/debug/app-firetv-debug.apk
   ```

The app appears in Fire TV's **Your Apps & Channels** row.

### Fire TV (Downloader app)
1. Install **Downloader** (by AFTVnews) from Fire TV app store
2. Host APK on LAN: `python3 -m http.server 8000` in APK directory
3. Open Downloader → `http://192.168.12.172:8000/app-firetv-debug.apk`

## Updating Service IPs

If an IP changes, update `ServiceRepository` in `MediaService.kt` and rebuild.
`network_security_config.xml` also needs the new IP added so Android allows
cleartext HTTP to it (LAN-only).

Current IPs:
- CT-300 mediastack — `192.168.12.30` (static)
- CT-104 vaultwarden — `192.168.12.104` (static)
- CT-107 authentik — `192.168.12.107` (static)
- Bahamut (AdGuard, wg-easy) — `192.168.12.244` (static)
- CT-900 ziggy (AI Chat) — `192.168.12.250` (DHCP, currently stopped)

## Project Structure

```
app/src/main/
├── java/com/tiamat/mediastack/
│   ├── MainActivity.kt        # Phone/tablet grid launcher
│   ├── TvMainActivity.kt      # Fire TV D-pad launcher
│   ├── WebViewActivity.kt     # Fullscreen WebView for services
│   ├── MediaService.kt        # Service model + ServiceRepository
│   └── ServiceAdapter.kt      # RecyclerView grid adapter
├── res/
│   ├── drawable/               # Service icons (vector XML)
│   ├── layout/                 # Activity + item layouts
│   ├── menu/                   # Toolbar overflow menu
│   ├── values/                 # Colors, strings, themes
│   └── xml/                    # Network security config
└── AndroidManifest.xml
```
