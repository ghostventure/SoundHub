# API integration phase

The current SwiftUI app is intentionally local-only while its navigation and workflows are being mirrored. It does not call SoundHub or SoundCloud endpoints, so the local-preview actions are not persistent and cannot change server data.

## Existing SoundHub API

The legacy Express service in `app/server.js` owns the SoundHub catalog and routes such as `GET /allSongs`, `POST /tree`, `/login`, `/mySongs`, and `/addSong`. These will be wired after the native UI is reviewed. The app must use the configured SoundHub service origin, not assume a local server is running.

## SoundCloud import

The intended import flow is to submit a SoundCloud track URL, resolve its metadata, and create a SoundHub song from the returned fields. SoundCloud now requires OAuth access tokens for API requests; token acquisition uses registered app credentials and tokens must be cached/refreshed. Keep the client secret on the server and never embed it in the Swift app. The current Import screen is a local form only; it does not make SoundCloud requests.

## Current native interactions

- Discover search, sort, song selection, local voting, favorites, and branching.
- Song Tree displays the parent/child lineage and supports selecting a version.
- MyHub sections show locally created songs, branches, and favorites.
- Create allows adding a local song/branch and selecting a local audio file.
- Profile and sign-in screens use temporary local preview state.
- No auth, SoundCloud metadata, song, profile, vote, favorite, or upload data is sent to a server yet.
