# SoundHub for macOS

Native SwiftUI interface for SoundHub’s main workflows. This milestone is focused on matching the program’s navigation and interactions; the app uses local preview data and makes no API requests.

The current interface includes Discover with search/sorting and track actions, a hierarchical Song Tree, MyHub collections, local profile editing, song/branch creation, a SoundCloud import form, About, and a persistent player. Local sign-in is a demo interaction only. New songs, votes, favorites, and profile edits live only for the current app session.

SoundCloud metadata lookup, account authentication, server persistence, cloud audio upload, and real account collections are deferred to the API integration phase. The import form accepts a track URL and metadata manually so its UI can be reviewed before the API is connected.

This port is based on the legacy React/Node source in this repository. No separate Windows client source was available for comparison, so this build does not claim Windows feature parity.

The existing SoundHub wave mark is used in the window and macOS Dock. Open `SoundHub.xcodeproj` and build the `SoundHub` scheme for macOS 13 or later. The app enforces a single running instance per macOS user.
