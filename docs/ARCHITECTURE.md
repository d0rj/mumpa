# Mumpa architecture

Decision record: 2026-10-08. Target platforms: Windows desktop and Android. This document describes the implementation contract; it does not by itself establish that a build or platform has passed validation.

## Product contract

Mumpa is a music player with a library, albums, artists, search, playlists, liked tracks, a persistent queue and offline music. Its desktop layout has a left library/navigation rail, a main content surface and a persistent player. Its phone layout uses bottom navigation and an expandable player. Dark surfaces, album artwork, clear typography and a green accent provide the requested familiar music-player experience while retaining Mumpa's own branding.

The same track can have a local-file source, a torrent source and a completed offline copy. Playback chooses a valid offline/local path before asking the torrent engine for a stream. No catalog subscription or cloud account is needed for local albums or user-provided magnet/.torrent sources.

A search result in the local library is immediately playable. Jackett is the default remote music provider. A pinned Windows backend is launched lazily; Android connects to an external Jackett endpoint. RuTracker.org still requires its user account configured in Jackett; a torrent engine alone cannot provide Spotify's commercial catalog. V1 must label library search and source import accurately rather than render nonfunctional catalog cards.

## Main decisions

| Concern | Choice | Reason and boundary |
| --- | --- | --- |
| UI and app logic | Flutter / Dart | One responsive codebase for Windows and Android. |
| Decoding and playback | `media_kit` plus its native audio libraries | Both platforms have native audio support; the player can open local paths and HTTP streams. Actual codecs are checked with fixtures in the built app. |
| Background controls | `audio_service` on Android, with an app audio handler around the same player | Android notification, headset/system controls and background playback. Windows can initially use its app controls; Windows system integration is an optional adapter. |
| Music tags | `audio_metadata_reader` | Pure Dart reads title, album, artist, duration and embedded art without another platform-specific native build. Metadata failures fall back to filenames and folder grouping. |
| Torrent transport | Managed TorrServer process, accessed through its HTTP API | Existing stream engine provides byte ranges, torrent metadata and caching; avoid writing a BitTorrent stack and a native Flutter FFI wrapper during v1. |
| Offline music | App-owned complete audio files | TorrServer's piece cache is transient and does not constitute an offline album. |
| Persistence | Versioned app-owned library state and atomic writes | Library, source records, playlists, favorites and settings must survive app restart. A SQLite repository can replace the storage implementation when collection sizes justify it. |

The player choice follows [media_kit's platform/features documentation](https://github.com/media-kit/media-kit/blob/main/README.md). Background integration follows [audio_service's platform and Android setup documentation](https://pub.dev/packages/audio_service). The metadata choice follows [audio_metadata_reader's format and API documentation](https://pub.dev/packages/audio_metadata_reader).

## Torrent alternatives

| Engine | Strong points | V1 cost / limitation |
| --- | --- | --- |
| TorrServer | Ready HTTP streaming API, portable executables, metadata, reader-driven cache, existing Lampa ecosystem | Manage process lifecycle and binary distribution. Transient caching still needs a separate complete-file offline layer. |
| libtorrent | Direct piece deadlines, priorities, file selection, resume data, mature BitTorrent implementation | Requires a C/C++ wrapper, FFI and native builds for Windows and Android; the app must also implement a seek-aware HTTP or custom read layer. |
| aria2 | Download/file-selection control and JSON-RPC; good complete-file downloader | JSON-RPC is control-plane, not a ready seek-aware media HTTP server. A stream server and contiguous-piece availability policy remain app responsibilities. |

Decision: TorrServer for v1, hidden behind `TorrentBackend` so it can later be replaced. This is an engineering inference from the official APIs, not an upstream claim that TorrServer is superior for every workload. [TorrServer](https://github.com/YouROK/TorrServer), [libtorrent streaming design](https://www.libtorrent.org/streaming.html), [aria2 manual](https://aria2.github.io/manual/en/html/aria2c.html).

## Modules and interfaces

```text
Responsive Flutter views
    -> App/library controller
        -> LibraryRepository  (library, playlists, likes, settings)
        -> LocalImporter      (picker, scan, metadata, artwork)
        -> PlaybackController (queue, repeat, shuffle, seeking)
        -> OfflineManager     (complete files, progress, quotas)
        -> TorrentBackend
            -> TorrServerClient (HTTP operations)
            -> ManagedEngine    (Windows process / Android channel)
    -> AudioHandler -> media_kit Player
```

Keep source resolution outside widgets. A widget asks to play a track ID; `PlaybackController` resolves its playable URI and tells the player to open it. Notifications and app controls call the same methods. A single controller owns current queue index and repeat/shuffle state, preventing a notification queue from diverging from the app queue.

Suggested domain records:

- `Track`: stable ID, title, artist, album artist, album ID, disc/track number, duration, artwork path, source ID, local path, torrent hash/file ID/path/size, favorite state.
- `Album`: stable ID, title, album artist, year, artwork path and ordered track IDs. Group by normalized album artist + album title + folder/source boundary to avoid accidental merging.
- `TorrentSource`: hash, original magnet or imported metainfo path, display title, imported time and selected audio files. Store returned server file IDs.
- `Playlist`: ID, title and ordered track IDs; queue edits do not mutate playlists.
- `OfflineEntry`: track ID, final path, expected/received bytes, state, pinned flag, retry information.
- `Settings`: schema version, engine mode, remote endpoint if selected, cache quota, audio volume and library roots.

App support storage:

```text
library.json (or library.sqlite)
artwork/<content-hash>.jpg
metainfo/<infohash>.torrent
offline/<track-id>.<ext>
offline/<track-id>.<ext>.part
torrserver/config/
torrserver/log/
```

Complete-file offline storage must use an application documents/support location rather than an OS-disposable temporary-cache directory. A missing original local file is marked unavailable and can be relinked; importing or deleting a library record does not delete the user's original audio file.

## Managed backend distribution

Pin engine **TorrServer MatriX.145.2**, source commit `bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9`. The release API was checked live on 2026-10-08. Use the regular assets rather than GStreamer variants because music decoding is handled by `media_kit`.

| Platform / ABI | Release asset | SHA-256 |
| --- | --- | --- |
| Windows x64 | `TorrServer-windows-amd64.exe` | `778bbc9bffb2e4d837a3a2c470fc2a4048d30f0a2004eb2553cd4a495b1bb2d6` |
| Android arm64-v8a | `TorrServer-android-arm64` | `44ef08f4e02fd325af63803617a27260eaeafc7385a47e9e6e244e98cc9cd5f6` |
| Android x86_64 | `TorrServer-android-amd64` | `66c51578a93a1d4b3e4ea3a25b4848e5e96032e0fb52564b6ba057700c09873e` |

Download URLs have the form `https://github.com/YouROK/TorrServer/releases/download/MatriX.145.2/<asset>`. Verify hashes before bundling/running. Keep an engine lock manifest in the repository, excluding generated binaries from normal source commits. [Pinned release](https://github.com/YouROK/TorrServer/releases/tag/MatriX.145.2), [release metadata](https://api.github.com/repos/YouROK/TorrServer/releases/tags/MatriX.145.2).

### Windows

Ship the verified executable beside the desktop app or download/verify it automatically on first use. Start it without a shell using `Process.start` and explicit arguments:

```text
-p <app-selected-port> -i 127.0.0.1 -d <app-state-dir> -l <app-log-file>
```

Bind the management HTTP API to loopback. Do not bind the BitTorrent peer transport to loopback: it must contact other peers. Wait for `/echo` with a startup deadline. Record the exact child PID/process object and stop only that owned process, never a global `killall`. Handle exit, startup failure and port conflict as recoverable user-visible states. An external endpoint remains an advanced option, not the default requirement.

The source flags are documented in the [pinned command implementation](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/cmd/main.go).

### Android

No ready Android AAR is included in this release. The official Android client downloads a CLI executable into `filesDir` and targets API 28; that exact execution pattern cannot be copied into a modern targetSdk app. [Official client startup](https://github.com/YouROK/TorrServe/blob/b7a8c8f8fbe8195e9a8dbdb9cc165cc9c6e73230/app/src/main/java/ru/yourok/torrserve/server/local/ServerFile.kt), [its targetSdk](https://github.com/YouROK/TorrServe/blob/b7a8c8f8fbe8195e9a8dbdb9cc165cc9c6e73230/app/build.gradle). Android restricts executing downloaded files from writable app home storage for API 29+ apps. [Android behavior contract](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission).

Practical v1 implementation proposal: package each verified Android executable under `jniLibs/<abi>/libtorrserver.so`, enable legacy native-library extraction, and launch the installed read-only executable from `applicationInfo.nativeLibraryDir` through a small Kotlin method channel. This packaging technique is an implementation proposal and must pass an installed APK test; it is not an upstream supported TorrServer Android Flutter integration. Android documents the [native library directory](https://developer.android.com/reference/android/content/pm/ApplicationInfo#nativeLibraryDir) and [extraction configuration](https://developer.android.com/guide/topics/manifest/application-element#extractNativeLibs).

Use a modern targetSdk, `INTERNET`, audio foreground-service permissions and a local-network cleartext configuration for the loopback player URL. Drain process output to avoid pipe deadlock. Own process lifecycle through the playback service, preserving it while torrent audio plays in the background. Do not enable root or accessibility services. A device/ABI that cannot start the packaged engine must show an actionable failure and permit a configured remote server; it must not silently claim standalone torrent support.

If packaged executable startup fails under the chosen Android runtime, the robust fallback is a Go/JNI in-process binding built from the pinned source; this needs an NDK/gomobile build and a native lifecycle adapter. Remote TorrServer is an optional interoperability mode, not the claimed completion of standalone Android support.

## Exact TorrServer HTTP contract

Source details were inspected at the pinned release and the current API. Use `Uri` query encoding and explicit request timeouts.

1. `GET /echo`: health/version.
2. `POST /torrents`, JSON `{"action":"add","link":"<magnet-or-torrent-url>","save_to_db":true,"category":"music"}`: returns status containing `hash`. Metadata may still be pending.
3. `POST /torrents`, JSON `{"action":"get","hash":"<hash>"}`: poll until `file_stats` contains files or a metadata deadline expires. Retry stays available for a temporarily seedless swarm.
4. Local `.torrent`: `POST /torrent/upload`, multipart field `file`; include `save=true` and `category=music`. Handle both the singleton status object and status-array response shape.
5. Stream: `GET /stream?link=<hash>&index=<file_stats.id>&play`. Query flags are present/absent. Passing `play=false` still supplies the flag and must not be used to disable it.
6. Statistics: `GET /stream?link=<hash>&stat` or the `get` status request. Display download speed/peers only when a real response exists.

**Use `file_stats.id` as `index`.** IDs are assigned after sorting torrent paths, starting at 1; they are not the original ordinal of the file in the metainfo. Persist the server ID and path together. Filter audio extensions after metadata resolution and keep natural disc/track ordering in the library.

The endpoint delegates audio bytes to Go `http.ServeContent`, so byte-range seeking and download resume can use HTTP range requests. Verify behavior against the shipped executable. [Torrent actions](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/web/api/torrents.go), [stream handler](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/web/api/stream.go), [.torrent upload](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/web/api/upload.go), [range-serving implementation](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/torr/stream.go), [sorted IDs](https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/server/torr/torrent.go).

## Playback, import and offline behavior

Local import runs outside the UI rendering path. Desktop folder scanning recursively discovers supported audio files, reads metadata, extracts artwork once and orders by disc/track/name. Embedded art is preferred, then folder `cover`/`folder`/`front` image, then a generated color placeholder. Individual corrupt tags must not abort the album. Android uses a document/audio picker and app-owned import copies when a persistent accessible path cannot be guaranteed; ordinary paths alone are insufficient for every SAF provider.

Queue controls: play/pause, previous/next, seek, volume, repeat off/all/one, shuffle and queue removal/reorder. On a failed source, stop buffering and retain the failed track with retry; prevent stale asynchronous resolutions from replacing a newer user selection. Store the queue and last position, but restore paused after process restart.

Offline downloads use the same torrent stream URL, one or a small bounded number at a time. Write `.part`, display actual received bytes, honor cancellation and preserve a resumable partial. A resume response must be HTTP 206 with the matching `Content-Range`; if the server returns HTTP 200, truncate/restart instead of appending duplicate bytes. Compare final bytes to `file_stats.length` and any declared response length, flush/close and atomically rename. Persist completion only after rename. Then rerun local metadata extraction and prefer the complete file during playback.

Never mark playback buffer completion, metadata caching or torrent piece-cache usage as an offline download. A cache quota evicts only unpinned app-owned complete/partial files, excluding the currently playing file. Album download selects each audio track, and its UI becomes fully offline only when all selected tracks finish. User-supplied originals are never quota-managed.

## Validation and completion gates

- Domain/adapter tests: sorted torrent IDs, metadata pending states, singleton/array upload responses, proper query encoding, HTTP error propagation, queue transitions, library serialization and cache resume/cancellation.
- Real local music fixtures: generated/tagged WAV, MP3 and FLAC (where codecs are available), multiple discs, embedded cover and broken tags; scan, play, seek, queue, restart and verify persisted albums.
- Real torrent fixture: generate original test audio plus metainfo/piece hashes, run an isolated local BitTorrent seed/tracker, add it to the actual pinned TorrServer, stream partial bytes and verify seeking. The pinned engine's parser/fork discards BEP19 webseed URLs, so a `url-list`-only fixture cannot provide its audio bytes. A mocked API passing is not a torrent playback result. See [verified upstream constraints](TORRSERVER_CONSTRAINTS.md).
- Offline fixture: download, verify exact length/hash, stop the engine and disconnect the fixture server, then play and seek the completed local file. Exercise cancel/resume and a quota boundary.
- Windows artifact: build release, launch the packaged app from its distribution directory and verify that bundled engine and player DLLs are present; inspect persistent UI at desktop/window sizes.
- Android artifact: build and install release/debug APK on an emulator or device, start the bundled ABI engine, import/play local files, play/seek torrent audio, background the activity and use notification controls. APK build alone does not establish Android runtime correctness.

Environment inventory at design time: Flutter/Dart, Go, Python and Node commands exist; Android Studio and an Android SDK directory exist; qBittorrent's executable exists. Availability is not a build or runtime result. Android emulators and connected devices still need inspection by the implementing agent.

## Distribution and future work

TorrServer is GPL-3.0. A distribution that includes it must retain its license and provide the corresponding engine source/version and notices; inspect package/player licenses in the release notices as well. Packaging and transport must be documented concretely with the shipped artifact. This is a distribution requirement, not a restriction on ordinary local-file or user-source playback.

Remote source discovery is implemented through Jackett/Torznab and the optional direct RuTracker catalog. Metadata enrichment, lyrics, recommendations, cross-device sync, equalization and crossfade remain separate improvements. iOS is outside the agreed v1 scope. These should not delay a working Windows/Android local+torrent+offline player or be represented as implemented controls before their real adapters exist.

## Catalog update — 2026-10-08

User explicitly chose Jackett as the default, including RuTracker.org support. `JackettService` verifies/extracts the v0.24.2806 archive in an isolate, starts a fixed executable with an app-owned private profile, disables updates and exposes its Torznab connection. Existing Jackett/Prowlarr URL/API-key connections remain supported. A guard prevents upstream migration of an unrelated Roaming profile. Readiness uses authenticated Torznab caps; configured RuTracker status uses the API-key indexer inventory. Credentials remain in Jackett's own profile and are never captured in notes.

`IndexerService` handles Audio searches, capability validation, magnet redirects and app-owned metainfo downloads. Home shows real feed results after a tracker is configured. A direct optional `RuTrackerService` parses live music categories, public forums and authenticated tracker rows, preserving CP1251 queries and lazy topic magnet resolution. `BrowserCatalogTransport` uses the platform WebView and lets the user complete ordinary site verification/login. It is initialized only when direct access is selected.

Windows UDP excluded ranges can reject a port that TCP accepts. `TorrentEngine` chooses unique random candidates and binds IPv4 TCP and UDP together before passing `--torrentaddr`; it detects early exits, cleans failed processes and records startup diagnostics. Sampling TCP port zero repeatedly is insufficient because Windows can allocate consecutive ports inside an entire UDP exclusion block.

## Catalog operation and Cloudflare update — 1.1.1

`SourceOperation` owns cancellation for one search or album inspection. Abortable HTTP requests stop superseded work without closing a shared client. Typing debounces for 600 ms, invalidates older responses immediately and exposes searching/completed states. Torznab results retain HTTP torrent and magnet separately, the indexer identity, original details URL and whether seeder statistics are known. RuTracker's description restores the original Cyrillic title when Jackett's title setting strips it.

Album inspection resolves and persists HTTP metainfo before uploading it to TorrServer; that path does not require live peers. Magnet metadata polling has a 25-second deadline, inspection an overall 60-second limit, and the interface shows stages and cancellation. The native decoder's initial network timeout is 60 seconds rather than media_kit's five-second default; unavailable public bytes still end in a surfaced playback error.

On Windows, `FlareSolverrService` optionally installs pinned FlareSolverr 3.5.2 from a Windows-only asset. File-backed ZIP extraction and critical-file hash checks run in an isolate. The hidden process gets isolated profile/temp paths and a loopback port. A Windows Job Object owns its descendants, including Chromium, and closes them on stop/exit. Logs never retain challenge HTML, cookies or credentials. A marker remembers enablement across restarts. `JackettService.configureFlareSolverr` uses the authenticated local dashboard API, preserving port, API key and existing indexers; only the solver endpoint and timeout change. Android uses a separately configured external Jackett/solver.

## Collection-first streaming — 1.1.2

Catalog and manual torrent actions use `AppController.openRelease` / `openTorrentCollection`, then `LibraryRepository.openSourceCollection`. One persisted `MusicPlaylist.sourceHash` identifies the collection. Metadata opening inserts supported tracks and creates the playlist atomically, without requesting audio. Reopening reuses its ID, preserves playlist edits and keeps cached/tag-enriched tracks. Playback starts on a track tap, with the entire visible collection as its queue and `contextPlaylistId` identifying the source playlist.

The decoder starts independently of complete-file downloads. Missing `autoCache` settings migrate to true; explicit false remains false. After the decoder opens and playback becomes active, only the current torrent track is queued with `priority: true`. A prioritized download interrupts a lower-priority HTTP or metadata wait, closes its partial writer, downloads the playing track, then resumes the previous partial through Range. Attempt-local cancellation prevents an old failure from corrupting a restarted job. Already active priority jobs are not restarted.

Adding to the active playlist appends membership and queue without replacing the current decoder/position. Ordinary add-to-playlist, play-next and enqueue actions remain available. Session persistence records original track order, shuffled order, cursor, playlist origin and position; selecting a new collection resets a previously restored position. Stream URLs use `play` without `preload`: the pinned server only invokes its blocking preload path when that flag is present. No engine cache configuration change is needed for early playback.
