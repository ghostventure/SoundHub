# SoundHub for macOS

Native SwiftUI interface for SoundHub’s main workflows. The app uses the legacy service’s song-node model, with local preview data as its initial catalog. Songs, branches, favorites, votes, and profile name edits persist in `~/Library/Application Support/SoundHub/SoundHubStore.json`.

The current interface includes Discover with search/sorting and track actions, a hierarchical Song Tree, MyHub collections, local profile editing, song/branch creation, a SoundCloud import form, About, and a persistent player. Local sign-in is a demo interaction only; passwords and signed-in sessions are not stored.

The About screen can connect to a configured SoundHub service. Discover loads the catalog in 24-song pages, and Song Tree refreshes its selected root. The existing Express service is not connected for account authentication or writes. SoundCloud metadata lookup, remote writes, cloud audio upload, and real account collections remain for API integration. The import form accepts a track URL and metadata manually.

This port is based on the legacy React/Node source in this repository. No separate Windows client source was available for comparison, so this build does not claim Windows feature parity.

The existing SoundHub wave mark is used in the window and macOS Dock. Open `SoundHub.xcodeproj` and build the `SoundHub` scheme for macOS 13 or later. The app enforces a single running instance per macOS user.
