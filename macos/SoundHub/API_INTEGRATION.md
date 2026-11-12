# API integration phase

The SwiftUI app currently persists its song-node catalog and member actions locally in Application Support. It does not call SoundHub or SoundCloud endpoints, so local changes do not reach server data or other devices.

## Existing SoundHub API

The legacy Express service in `app/server.js` owns the SoundHub catalog and routes such as `GET /allSongs`, `POST /tree`, `/login`, `/mySongs`, and `/addSong`. The native About screen now accepts a service base URL and can load `GET /allSongs`; the existing tree request method remains available. This is read-only integration: the client does not submit account credentials or member writes. The base URL is saved in macOS preferences and must be supplied by the operator; no production service origin is present in the repository.

Before enabling remote member actions, the service needs a supported authentication/session contract and authorization based on the authenticated principal. Current routes accept caller-supplied user IDs and author fields, and must not be used for native writes as-is. The Swift app must never connect directly to MariaDB or bundle database/S3 credentials.

## SoundCloud import

The intended import flow is to submit a SoundCloud track URL, resolve its metadata, and create a SoundHub song from the returned fields. SoundCloud now requires OAuth access tokens for API requests; token acquisition uses registered app credentials and tokens must be cached/refreshed. Keep the client secret on the server and never embed it in the Swift app. The current Import screen is a local form only; it does not make SoundCloud requests.

## Current native interactions

- Discover search, sort, song selection, local voting, favorites, and branching.
- Song Tree displays the parent/child lineage and supports selecting a version.
- MyHub sections show locally created songs, branches, and favorites.
- Create allows adding a local song/branch and selecting a local audio file.
- Profile and sign-in screens use temporary local preview state.
- Song, profile, vote, favorite, and branch changes are persisted on this Mac. Member mutations, credentials, SoundCloud metadata, and uploads are not sent to a server.
- When a service URL is configured from About, Discover and Song Tree use the server's `/allSongs` catalog. Locally created songs remain appended on this Mac. The native app still does not authenticate or send mutations to the legacy backend.
