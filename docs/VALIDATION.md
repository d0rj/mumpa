# Mumpa 1.0.0 verification — 2026-10-08

Verified locally with Flutter 3.44.4 stable / Dart 3.12.2 on Windows, plus the Android API 35 x86_64 emulator. These checks establish the listed behavior; they do not establish that every public swarm, codec or physical phone works.

## Automated checks

- `flutter analyze`: no issues.
- `flutter test`: 20 passing tests. Domain grouping/disc ordering; library/playlist/likes persistence and backup recovery; import deduplication without altering originals; queue/repeat/shuffle/session restoration; cancellation of a pending source without late playback; system stop publishes idle and the queue resumes; local/offline source priority; server file IDs and stream URL encoding; Torznab parsing/errors; cold-engine readiness; app-owned metainfo recovery after reset; exact resumable HTTP downloads, pause/resume and quota.
- Responsive widget tests render home, library, search, album, liked, playlists, downloads and settings at 1380×860, 850×700, 390×844 and 320×568, exercise album playback/search/import dialog, and capture previews with actual fonts. Music grids and track/source/download lists use lazy slivers.
- Native Windows integration passes: real libmpv local playback/seek; real TorrServer streaming/seek; HTTP 206 byte-range equals original bytes; complete download SHA-256 equals original; real engine stop/start restores torrent; offline playback/seek succeeds with both the engine and seeder stopped.
- Native Android integration passes the same checks and verifies registration of the real Android audio service. Local emulator: API 35, Google APIs x86_64, software GPU. ARM64/ARMv7 APKs compile; physical ARM devices have not been connected for runtime testing.
- The installed release x86_64 APK continues playback after Home, reports `PLAYING` with advancing position in Android's real media session, and responds to background system pause/resume. Release resource shrinking initially removed name-resolved `audio_service` icons; `res/raw/keep.xml` retains them, and the corrected APK no longer reports the icon exception. Local evidence: `test-output/android-media-background.log`, `android-media-pause.log`, `android-media-resume.log`.

The original 24-second stereo WAV is 2,116,844 bytes. SHA-256: `f762a101b2d8ed4d05d83e073b81ad38b8b3dddfed8f398f8500f89bae0fcad6`. The native fixture's seeder served 130 piece requests before engine restart. No external music catalog or public swarm is used in these tests.

Local run logs: `test-output/unit-tests.log`, `test-output/windows-e2e.log`, `test-output/android-e2e.log`. Integration result lines start with `MUMPA_E2E`. The independent headless Android engine probe also confirms exact HTTP Range bytes over a real peer connection.

## Builds and delivery

Windows x64 release and Android split ABI release packages are built from the checked code. `artifacts/SHA256.json` records delivered file sizes/hashes. Windows needs the entire release directory, including Flutter, libmpv, plugin DLLs and assets. Android executables are extracted ABI libraries; the Windows engine asset is excluded from Android packages.

The APKs use the local development signing key for direct installation. Public-store signing, Store submission and Windows code signing are separate release operations. No account/cloud synchronization, Spotify catalog/API, licensed catalog service, recommendation server or preconfigured torrent indexer is implemented; local search and a user-configured Torznab API are supported.

## Repeated firewall dialog and apparent stall

Earlier Windows integration runs extracted TorrServer under a new temporary library directory. Each executable path had a new firewall identity. The Windows binary is now hash-verified at a fixed application-support runtime path; per-test metadata/cache still stay isolated. No firewall rules were edited. First use of a new installed engine identity may still produce Windows' normal network permission dialog.

The initial source fixture provided only HTTP webseed bytes, unsupported by the pinned torrent fork. The replacement plaintext seeder initially met the engine's outbound MSE handshake, then its Dart tracker incorrectly decoded binary `info_hash` as UTF-8. Those test-fixture errors left native playback waiting for unavailable bytes. The final fixture initiates plaintext peer wire, decodes announce fields with Latin-1, and passes on both platforms.

Player network errors now stop waiting and surface a readable error; pressing pause while loading cancels that playback request. Windows engine hash checks run in an isolate. New managed configurations disable LAN discovery/broadcast services. Native test processes and the hidden emulator are closed after verification.

## Implementation map

The architecture document records the proposed boundaries. The delivered files implement them as follows: `LibraryRepository` (JSON/import/tags/artwork), `TorrentEngine` + `TorrentService` (process/API/metainfo), `DownloadRepository` (complete-file offline transfers), `PlaybackController` + `NativeAudioBackend` + `SystemAudioHandler` (queue/decoder/system audio), `AppController` (view state/actions), and responsive Flutter widgets under `lib/ui`.

Actual app support directories are `artwork/`, `torrents/`, `downloads/`, `engine/` and Windows `runtime/`, alongside `library.json`/`.bak`; names in the initial architecture's illustrative tree are not runtime paths.
