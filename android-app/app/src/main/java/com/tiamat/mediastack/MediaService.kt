package com.tiamat.mediastack

/**
 * Represents a content service shown in the dashboard.
 *
 * Post-*arr: the app is a search-and-watch shortcut layer. Riven (in CT-300)
 * does scraping + Real-Debrid uploads + RivenVFS mounting; Jellyfin (also in
 * CT-300) plays from /mount. The other services here are infra/admin.
 */
data class MediaService(
    val name:        String,
    val url:         String,
    val description: String,
    val iconResId:   Int,
    val category:    String = "",
    val available:   Boolean = true
)

/**
 * Service list — bulletproof-mediastack (post-*arr architecture).
 *
 * Everything related to media playback now lives in CT-300 (192.168.12.30).
 * Riven (frontend + backend + RivenVFS) replaces Jellyseerr + Sonarr/Radarr +
 * Prowlarr + qBittorrent + rdt-client. Jellyfin still serves playback.
 */
object ServiceRepository {

    fun getServices(): List<MediaService> = listOf(

        // ── Watch ──

        MediaService(
            name        = "Jellyfin",
            url         = "http://192.168.12.30:8096",
            description = "Watch movies, TV, music",
            iconResId   = R.drawable.ic_service_jellyfin,
            category    = "Watch"
        ),

        MediaService(
            name        = "Live TV",
            url         = "http://192.168.12.30:8096/web/#/livetv.html",
            description = "IPTV via Jellyfin",
            iconResId   = R.drawable.ic_service_livetv,
            category    = "Watch"
        ),

        // ── Search & Add ──

        MediaService(
            name        = "Search & Add",
            url         = "http://192.168.12.30:3000",
            description = "Riven — search and request shows/movies",
            iconResId   = R.drawable.ic_service_overseerr,
            category    = "Search"
        ),

        // ── Infrastructure ──

        MediaService(
            name        = "AdGuard",
            url         = "http://192.168.12.244:3000",
            description = "DNS & ad-blocking",
            iconResId   = R.drawable.ic_service_adguard,
            category    = "Infra"
        ),

        MediaService(
            name        = "VPN",
            url         = "http://192.168.12.244:51821",
            description = "wg-easy — WireGuard clients",
            iconResId   = R.drawable.ic_service_wgeasy,
            category    = "Infra"
        ),

        MediaService(
            name        = "Passwords",
            url         = "https://192.168.12.104",
            description = "Vaultwarden",
            iconResId   = R.drawable.ic_service_vaultwarden,
            category    = "Infra"
        ),

        MediaService(
            name        = "Auth",
            url         = "http://192.168.12.107:9000",
            description = "Authentik SSO",
            iconResId   = R.drawable.ic_service_authentik,
            category    = "Infra"
        ),

        // ── Tools ──

        MediaService(
            name        = "Riven API",
            url         = "http://192.168.12.30:8080",
            description = "Riven backend (diagnostics)",
            iconResId   = R.drawable.ic_service_traefik,
            category    = "Tools"
        ),

        MediaService(
            name        = "AI Chat",
            url         = "http://192.168.12.250:3000",
            description = "Open WebUI — Ollama LLMs",
            iconResId   = R.drawable.ic_service_openwebui,
            category    = "Tools",
            available   = false  // CT-900 ziggy currently stopped
        )
    )
}
