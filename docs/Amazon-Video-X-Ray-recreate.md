To recreate Amazon Video’s X-Ray capability (seeing actors, music, and scene details in real-time) in Jellyfin, you have to use a combination of specific plugins and third-party clients. Jellyfin doesn't have a single "one-click" X-Ray feature, but you can build a very close approximation.

Here is how to set it up:
1. The "Cast & Credits" Layer (ActorPlus Plugin)

While the standard Jellyfin "People" list only shows at the start, the ActorPlus plugin enhances how actor data is displayed and linked. It allows you to see more detailed filmographies and information, moving it closer to the "Who is that actor?" utility of X-Ray.

    How to install:

        Go to Dashboard > Plugins > Repositories.

        Add the following repository URL: [https://raw.githubusercontent.com/Druidblack/Jellyfin.Plugin.ActorPlus/master/manifest.json](https://raw.githubusercontent.com/Druidblack/Jellyfin.Plugin.ActorPlus/master/manifest.json)

        Go to the Catalog, find ActorPlus, and install it.

        Restart your Jellyfin server.

2. Using Infuse (The Best "X-Ray" Client)

If you use an Apple TV, iPhone, or iPad, the third-party client Infuse provides the closest visual experience to X-Ray.

    The Feature: During playback, you can swipe up to see a list of actors in that specific title, including their roles and high-quality portraits.

    Setup: Connect Infuse to your Jellyfin server using Direct Mode (Settings > Shares > [Your Server] > Library Mode: OFF). This ensures Infuse pulls your Jellyfin metadata but presents it in its highly polished "X-Ray-like" interface.

3. Music Recognition (The "Themerr" Plugin)

Amazon X-Ray often identifies the song playing in a scene. While Jellyfin can't "Shazam" a live scene yet, the Themerr plugin adds theme songs and music metadata to your movie and show pages.

    Repo: [https://app.lizardbyte.dev/jellyfin-plugin-repo/manifest.json](https://app.lizardbyte.dev/jellyfin-plugin-repo/manifest.json)

    Utility: It helps bridge the gap for identifying the "vibe" and key tracks associated with the media you are viewing.

4. Scene Selection & "In-Player" Navigation

A key part of X-Ray is jumping to specific scenes.

    Jellyfin-Vue: If you use the experimental Jellyfin-Vue web client, it features a revamped playback manager that includes an episode/scene list overlay inside the player itself (very similar to the Amazon UI).

    Chapter Images: Ensure you have the "Extract chapter images" task enabled in your Library settings. This creates visual thumbnails for the playback bar so you can "see" the scenes as you scrub, just like X-Ray.

Summary Table: Recreating X-Ray
X-Ray Feature	Jellyfin Equivalent	Tool/Plugin Required
Actor Info	Detailed Actor Overlay	ActorPlus Plugin
Music ID	Theme Music/Metadata	Themerr Plugin
Scene List	Visual Chapter Scrubbing	Chapter Image Extraction
Clean UI	Swipe-up Cast List	Infuse (Apple devices)

