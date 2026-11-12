# SoundHub native macOS plan

## Goal

Build a native SwiftUI macOS client for SoundHub's open-source music workflows while keeping the existing React/Node service as the initial behavior reference. The native client must use a documented, authenticated API; it must not connect directly to MariaDB or contain AWS credentials.

## Initial repository findings

- The checked-out repository is `SoundHub/SoundHub`, branch `dev`, at `3cd08de`.
- The existing client is React 0.13/Flux and the service is Node 0.12-era Express, Sequelize 3, MariaDB, and an S3 upload route.
- The core product model is a song-node tree: users listen, vote, favorite, branch an existing song, and follow its contribution tree.
- Express endpoints include `/login`, `/signup`, `/getuser`, `/allSongs`, `/allSongSort`, `/tree`, `/mySongs`, `/myForks`, `/myFavs`, `/addFork`, `/addFav`, `/myVotes`, `/addVote`, `/addSong`, profile updates, and `/s3` upload handling.
- Backend hosting, database availability, and the state of the historical AWS bucket are not verified. No production services were contacted.

## Phased implementation

1. **Native foundation:** create an isolated SwiftUI macOS app target under `macos/SoundHub`, using clearly labeled local preview data while the interface is built out.
2. **Workflow parity:** mirror Discover, Song Tree, MyHub, profile, song/branch creation, SoundCloud import, and player interactions with local session state. Keep the current milestone API-free.
3. **SoundCloud import:** connect the import form to SoundCloud metadata resolution using OAuth access tokens. Keep the app secret on the server and cache/refresh tokens there.
4. **SoundHub data:** connect catalog, tree, account state, and persistence through the existing SoundHub service after its API origin and secure auth contract are confirmed.
5. **Member actions and uploads:** after server-side authorization exists, add favorite, vote, branch, and profile writes. Use server-authorized upload URLs or an authenticated upload endpoint; never bundle AWS access keys.
6. **Packaging:** maintain the app icon and one-instance behavior, then complete offline/cache policy, a local Debug build, and separate Developer ID signing/notarization work.

## Backend blockers found in source

- `app/server.js` has no session/token middleware. Several POST routes trust a caller-supplied numeric `userId`; `/addSong` also accepts client-supplied author fields. A native app cannot securely use those mutation routes as written.
- The browser stores a readable ID/username/avatar cookie and uses the ID as login state; the server does not validate it. Unknown-user login can dereference a missing result.
- `app/db.js` has a literal MariaDB username/password and local host configuration. Move service secrets to environment/secret storage and rotate any credential that was ever used outside local development.
- Raw SQL interpolates caller-supplied IDs in favorites/forks/votes queries, and song sorting interpolates caller-supplied sort order. Parameterize IDs and use a strict sort-key allowlist.
- `/login` returns a user model as `response.user`; `/signup` returns a user model as `userData`. Both may serialize the password hash. Return a narrow public user DTO and never return password hashes.
- `/getuser` loads by a caller-supplied ID. Define public/private fields and enforce authenticated ownership for private profile data.
- The `/s3` route uses a hard-coded bucket and public-read ACL. Review upload authorization, file type/size, object naming, malware/abuse controls, and whether audio is intentionally public before reuse.
- Dependency versions are very old. Upgrade and security review the service before exposing it to a new native client or deploying changes.

## Decisions needed before connecting the app to a live service

- Confirm the authoritative API base URL and whether it is currently operated.
- Confirm whether the server may be updated to issue bearer sessions and enforce user identity for writes.
- Confirm public audio visibility, user/profile field visibility, upload policy, and attribution/licensing rules for branches.
- Confirm the supported macOS minimum and whether the first release is a local preview or public distribution.

## Guardrails

- No production database or S3 access until an owner-provided environment and authorization path are confirmed.
- Do not embed MariaDB or AWS credentials in the Swift app.
- Keep the first native milestone read-only until API authentication is corrected.
- Preserve the `dev` branch and existing web source; put the native implementation under `macos/SoundHub`.

## Initial implementation assignments

- Native SwiftUI foundation: add the isolated app shell and document API integration seams.
- Product workflow map: prioritize anonymous discovery/listening and tree exploration before member-only writes.
- Backend review: document authorization, SQL, response-shape, and upload blockers before enabling login, favorites, votes, branches, or uploads.

## Current implementation status

- The native SwiftUI target exists at `macos/SoundHub` and builds for macOS on both `arm64` and `x86_64` with Xcode 16.4.
- This milestone mirrors the interface and interactions without making API calls: Discover, hierarchical Song Tree, MyHub collections, local sign-in, profile editing, song and branch creation, SoundCloud import form, About, and the persistent player.
- This port is based on the legacy React/Node source in this repository. No separate Windows client was present in the checkout, so Windows feature parity has not been assessed or claimed.
- The native app persists the song-node catalog, branches, favorites, votes, and profile name edits in Application Support. The About screen accepts a service URL; Discover loads paginated `/allSongSort` results and Song Tree reads `/tree`. Remote writes remain disabled until the service enforces authenticated identity. Authenticated accounts, uploads, and SoundCloud metadata resolution remain future work.
- The app now uses the existing SoundHub wave mark in its window and Dock icon, and enforces one process per macOS user with bundle-ID detection and an Application Support file lock.
- The current universal build succeeds; the app was launched, then opened again with macOS's forced-new-instance option and confirmed to remain as one process. `git diff --check` passed. No API request, production service, or test suite has been exercised.
