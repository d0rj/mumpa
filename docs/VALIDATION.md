# Mumpa verification — 2026-10-10

## 1.2.1 collection search and discography albums

- **152 unit/widget tests pass**, one opt-in Jackett test is skipped, and
  `flutter analyze --no-pub` reports no issues. New checks cover filtered views
  retaining the original queue and playlist context, 320 / 1200 px layouts,
  search options and format filtering, disabled empty lyrics and tab updates
  while paused, a 152 px desktop volume slider, and invariant album-column
  positions across download states. Artwork tests include an album subset whose
  embedded image is on another library track, exact artist/album matching,
  meaningful album parentheses, coalescing and offline disk-cache restart.
  Logs: `unit-1.2.1.log`, `analyze-1.2.1.log`.
- Fifteen discography tests cover folder dates/categories, codec/CD wrappers,
  track/disc numbers, a genuine leaf named Album, unchanged legacy IDs/favorites/
  cached paths/playlists, once-only cached tag migration, explicit conflicting
  albums and flat mixed collections. Original metadata-only FLAC/ID3/MP4 fixtures
  verify ALBUMARTIST-only propagation, separate MP3 TPE1/TPE2 and M4A ©ART/aART
  credits, lyrics/artwork, two MP4 meta layouts, UTF-16BE credits and bounded
  oversized-atom rejection. These are tag-parser proofs, not audio decode proofs.
- A native Windows opt-in check loads a copy of the existing library into an
  isolated profile. **Ежемесячные becomes 72 albums containing 493 tracks**;
  opening an album remains inside its source collection. Local filtering selects
  the existing fully downloaded favorite **Роженица в метро**; native libmpv
  reports **240457 ms** duration and advances to **2950 ms**. Its queue still
  contains all 493 tracks in order. Its tag album is **Короли Абстракта VI -
  Мультивселенная ЕЖЕ**, and embedded artwork renders in the row/player.
  All copied favorite IDs and track IDs survive migration. The source profile
  is read only by this test. The real exact-album lookup for **Daft Punk /
  Discovery** retrieves **17616 bytes** of Cover Art Archive artwork and reuses
  the cached file. This is a cached native music proof, separate from the public
  swarm proof recorded for 1.2.0. Evidence: `collection-1.2.1.log` / `.json`,
  `collection-albums-1.2.1.png`, `collection-filter-1.2.1.png`.
- Native Windows and Android API 35 x86_64 pass the outgoing peer-wire fixture:
  original WAV audio plays in **1461 / 1611 ms**, with **376832 bytes** served
  out of **2116844** before the full-file download is ready. Both retry rejected
  MSE with plaintext, preserve favorites, automatically cache the complete file
  with the expected SHA256, pass exact HTTP Range and seek, restore the torrent
  after engine restart, play offline with engine/seeder stopped and release
  readers across three peerless retries. Android registers its audio service.
  These are controlled original-content fixtures; physical Android hardware
  is untested. Logs: `windows-outgoing-1.2.1.log`, `android-outgoing-1.2.1.log`.
- Windows **1.2.1+9** and all three Android release APKs build. Their engine
  files match the pinned raw/stripped hashes; each APK contains its libmpv and
  excludes Windows/helper assets. APK sizes: **43741723 / 43876399 / 45083181
  bytes** for ARM64 / ARMv7 / x86_64. The x86_64 release installs and launches
  as **1.2.1 / versionCode 4009** on the own API 35 emulator, without an app
  runtime crash. Evidence: `windows-release-1.2.1.log`,
  `android-release-1.2.1.log`, `apk-layout-1.2.1.json`,
  `android-release-startup-1.2.1.json`.
- The final Windows package starts against the existing production profile,
  hides to tray, restores and exits with **code 0**, stopping its managed helpers.
  Restart preserves all **10 favorite IDs**, playlist favorites, library IDs,
  exact playlist membership/order, the original playback queue, Jackett port/key,
  RuTracker.org configuration, automatic caching, the **256 MB** metadata cache
  limit and the authorized **Беспроводная сеть** torrent interface. All applicable
  legacy torrent layouts acquire their migration marker. One final packaged
  instance remains open. Evidence: `packaged-startup-1.2.1.json`.
  The initial checker copy misdecoded its Russian interface literal; the corrected
  UTF-8 checker and its full rerun pass. The application setting was preserved
  during both runs.

Discography grouping, metadata precedence and cache behavior are described in
[MUSIC_DISCOVERY.md](MUSIC_DISCOVERY.md). No VPN, route or firewall change is
needed for these UI/data changes.

## 1.2.0 music discovery, persistent cache and Windows player

- **117 unit/widget tests pass**, one opt-in Jackett test is skipped, and
  `flutter analyze --no-pub` reports no issues. Coverage includes playlist and
  source-collection favorites across profile reload/deletion, persistent FIFO
  eviction and quota reduction, TTL, corrupt-index recovery, immutable cache
  receive buffers, concurrent clear, and delayed multi-stage artist/cover work
  that must not repopulate a cleared cache. UI checks cover animation pause and
  reduced motion, square loading indicators, independent artist gestures,
  stable asynchronous artwork, and 320 / 1200 px layouts. Shutdown checks inject
  failures into session saving, decoder, engine, helpers and library flush;
  cleanup still waits for the catalog browser before native quit completion.
  Logs: `test-output/unit-1.2.0.log`, `analyze-1.2.0.log`.
- A fresh native Windows discovery test uses the existing configured Jackett
  endpoint/key in memory and an isolated library. Live MusicBrainz returns
  **Ежемесячные with 15 release groups**. Searching **Роженица в метро** finds
  one verified MP3 file in four inspected collections. Playback uses a fresh
  HTTP torrent source, reports **240457 ms** duration and advances to **4480 ms**;
  the collection becomes the queue. Opening plus the 2.5-second playback probe
  takes **6788 ms**. Auto-cache is disabled only in this isolated network proof;
  the user's saved setting is unchanged. The independently requested Discovery
  Cover Art Archive thumbnail is **17616 bytes**, and the next request reuses
  its cached file. Logs/evidence: `music-discovery-1.2.0.log` / `.json`;
  `music-versions-1.2.0.png` shows the actual result UI. This proves one reachable
  song, not availability of every recording or format. An initial cover probe
  encountered a transient miss; the completed end-to-end rerun passes.
- Native Windows shell integration confirms creation of SMTC, tray icon and
  thumbnail toolbar; real window media commands and thumbnail notifications
  control Play/Pause/Previous/Next. Closing hides the window, audio position
  advances while hidden, and restoring works. The isolated test has muted
  original fixture audio. Logs/evidence: `windows-shell-1.2.0.log` / `.json`.
  A specific physical speaker's hardware button has not been pressed by this
  test; it must emit a standard Windows media command.
- A separate release fixture creates a WebView environment, a headless view
  and an open browser in a temporary profile, deliberately leaving all three
  native owners alive until WM_CLOSE. The process exits with **code 0**, without
  forced termination or timeout, and its temporary profile is removed.
  The pinned Windows WebView overlay shuts down its current-thread dispatcher
  while the Flutter engine is still alive, before COM teardown. This fixes a
  native exit crash also reproduced in the previous 1.1.5 package. Evidence:
  `windows-browser-build-1.2.0.log`,
  `windows-browser-exit-1.2.0.result.json`.
- Native Windows and Android API 35 x86_64 pass local audio, outgoing peer-wire
  streaming, favorites, automatic full-file caching, complete SHA256, exact
  HTTP Range, seek, restart/offline and repeated peerless-reader cancellation.
  First audio advances in **1448 / 1507 ms**, with **376832 / 360448 bytes**
  served out of **2116844** before the full download is ready. Both observe one
  rejected MSE handshake followed by an accepted plaintext connection. Android
  registers its background audio service. These are local original-content
  fixtures; physical Android hardware is untested. Logs:
  `windows-outgoing-1.2.0.log`, `android-outgoing-1.2.0.log`.
- The existing configured services were started through the old packaged app
  before the live discovery check. All **7 favorite IDs**, library track IDs,
  Jackett port/key, RuTracker.org configuration, automatic music caching and
  the authorized Wi-Fi interface survive that startup. VPN, system routes and
  firewall were not modified.
- The final **1.2.0 Windows package** also starts against that existing profile,
  reaches healthy managed Jackett/FlareSolverr, hides to tray and restores,
  stops managed helpers on explicit exit, and exits with **code 0**. Restart
  preserves all 7 favorite IDs, playlist favorites, library track IDs, Jackett
  port/key, RuTracker.org configuration, automatic caching and the Wi-Fi
  interface. One final packaged instance remains open.
  Evidence: `packaged-startup-1.2.0.json`.
- Windows **1.2.0+8** and ARM64 / ARMv7 / x86_64 Android release APKs build.
  APK sizes are **43702991 / 43834843 / 45042717 bytes**. The Windows engine
  matches its pinned SHA256, each APK includes the exact stripped pinned engine
  for its ABI plus libmpv, and Windows/helper archives are absent from Android.
  The x86_64 release installs and launches as **1.2.0 / versionCode 4008** on the
  own API 35 emulator, without an app runtime crash. Evidence:
  `windows-release-1.2.0.log`, `android-release-1.2.0.log`,
  `apk-layout-1.2.0.json`, `android-release-startup-1.2.0.json`.

New behavior and its limits are documented in [MUSIC_DISCOVERY.md](MUSIC_DISCOVERY.md)
and [WINDOWS_PLAYER.md](WINDOWS_PLAYER.md). In particular, metadata/file matches
do not imply a reachable swarm; Clean/Uncensored labels describe source text,
and the metadata FIFO quota does not remove local or completed offline music.

## 1.1.5 explicit source interface and live route comparison

The current public favorites are alive: a separate qBittorrent 5.1.2 temporary
profile receives 30 / 12 peers from the original trackers and downloads both
selected files over IPv4 TCP. A 50 ms socket capture plus read-only Windows
route lookup shows its successful announces using Wi-Fi. Mumpa and replayed
tracker HTTP requests use the VPN interface and receive no announce response;
explicitly binding those requests to the same VPN source also fails. This
identifies a route difference, not a measured external IP or a server-side
explanation. The authorized OpenTrackr announce yields 5 / 4 leecher peers,
zero seeders and no reachable TCP endpoints. After separate user authorization,
native Mumpa plays an existing favorite through Wi-Fi, as measured below. No
VPN, system routes or firewall rules were changed.

Windows now offers an optional interface selector, defaulting to the system
route. It saves the name, resolves the current IPv4 address at engine startup,
and fails if the named interface is missing. The setting applies after restart;
the view explains direct traffic and provider-IP exposure. The user authorized
direct torrent traffic through Wi-Fi, and the current profile now selects
`Беспроводная сеть` with automatic complete-track caching still enabled.

- Managed `MatriX.145.2-mumpa3` binds outgoing TCP peers and HTTP(S)/UDP trackers
  to an explicit listener address. uTP and DHT use the same bound socket. It
  disables the incompatible address family, skips unrelated automatic public-IP
  discovery, preserves explicit announce-IP overrides, and rejects incompatible
  proxy/source settings. Tracker DNS selection skips incompatible IPv4/IPv6
  candidates without reverting to an unbound connection.
- All 24 focused Go tests pass using loopback only. Nineteen torrent/tracker
  tests pass three times. A negative control removes only DNS-family filtering:
  eight explicit-source cases fail while six default/wildcard/empty cases pass.
  Evidence: `engine-patches/checks/mumpa3-regressions.log`,
  `mumpa3-source-binding-repeat.log`, `mumpa3-family-negative-control.log`.
- All four native engine targets build with locked source, modules and
  toolchains. A fresh Windows build reproduces SHA256
  `281a77382ffeb5cfd4ca8b2f5be05badc2c0633a64f70c359e0dd0037b2c9e74`.
  All binary hashes are in `engine-patches/managed-engine.lock.json`; complete
  patched source accompanies the release.
- **80 unit/widget tests pass**, one opt-in Jackett check is skipped, and static
  analysis is clean. New cases cover the untouched default route, DHCP address
  changes, missing/invalid selections and no native launch on a missing source.
- Native Windows and Android API 35 x86_64 pass the final engine's outgoing
  BitTorrent fixture. First audio advances in **1472 / 1580 ms**, with
  **393,216 / 360,448 bytes** served out of **2,116,844** while automatic full-track
  caching is incomplete. Both observe one rejected MSE connection followed by
  one accepted plaintext connection. Complete SHA256, seek, exact HTTP Range,
  restart/offline and three reader cancellations pass; Android's audio service
  is registered. Evidence: `test-output/windows-outgoing-mumpa3-final.log` and
  `android-outgoing-mumpa3-final.log`. These are local original-content fixtures.
- Windows **1.1.5+7** and all three Android release APKs build and are packaged.
  The Windows ZIP is **487,592,206 bytes**; ARM64/ARMv7/x86_64 APKs are
  **43,609,967 / 43,737,511 / 44,952,681 bytes**. Their native engine hashes
  match the lock after the pinned NDK's `llvm-strip --strip-unneeded`; libmpv
  is present and Windows assets are absent. The x86_64 release installs and
  launches as **1.1.5 / versionCode 4007** on API 35 without an app runtime crash.
- Packaged Windows startup preserves all four likes, library track IDs,
  RuTracker.org, Jackett port/key, automatic caching and the unchanged system
  torrent route at the initial checkpoint. Managed FlareSolverr is healthy.
  Evidence: `test-output/packaged-startup-1.1.5.json`, `apk-layout-1.1.5.json`,
  `android-release-startup-1.1.5.json` and final release build logs. The own
  emulator was closed after validation. Physical Android hardware is untested.
- **Real favorite network playback passes.** The isolated native Windows test
  uses the actual `Роженица в метро` favorite/metainfo and the normal managed
  engine selected through `FAVORITES_INTERFACE`. No external diagnostic server,
  fixture music, qBittorrent payload or completed local/cache file is used;
  automatic caching is disabled in this isolated network-only test. First
  advancing audio arrives in **2959 ms**; the decoder reports **240457 ms**
  duration and advances to **2650 ms**, with **4 active peers** and a fresh HTTP
  torrent source. `REQUIRE_FAVORITES_PLAYBACK=true` passes and the command exits
  zero. Evidence: `engine-patches/checks/favorites-wifi-native.json` and
  `test-output/real-favorites-wifi-native.log`.
- The normal user profile is then updated only in `torrentInterface` and the
  packaged app restarted. All other library data is preserved, including four
  likes, track IDs, Jackett/RuTracker.org and automatic caching. Evidence:
  `test-output/wifi-profile-applied.json`, `packaged-startup-wifi-1.1.5.json`.

Reproduce the authorized network check with the actual Windows interface name:
`flutter test integration_test/favorites_test.dart -d windows --dart-define=REAL_FAVORITES_TEST=true --dart-define=REQUIRE_FAVORITES_PLAYBACK=true --dart-define="FAVORITES_INTERFACE=Беспроводная сеть"`.

The first Android release attempt used `--no-pub` after the native test and
retained a dev-only Java plugin registration. The ordinary Flutter build
regenerates release tooling and succeeds without dependency-version changes;
README records that build-order constraint. The explicit-source DHT mode can
start with a random non-BEP42-bound ID when no public address is configured;
strict public DHT acceptance remains unverified.

Sanitized live comparison is in `engine-patches/checks/network-comparison.json`.
See [network diagnosis](NETWORK_DIAGNOSTICS.md) for the met acceptance criterion:
an existing favorite decoded from the network and advancing for at least 2.5
seconds. Independent downloads and local fixtures did not satisfy that check.
This single successful public favorite does not prove every swarm or physical
Android device will be reachable.

## 1.1.4 outgoing peers and strict public-favorite playback

Managed `MatriX.145.2-mumpa2` fixes two source-confirmed defects: an outgoing MSE error skipped the optional plaintext fallback, and HTTP tracker IP parameters included a node port (`IP:0`). Auto-detected public IP remains available for DHT/peer protocols, while tracker IP overrides now require explicit configuration. These protocol fixes do **not** establish public-swarm reachability through the observed network path.

- Twelve focused Go regressions plus four IPv4/IPv6 subcases pass: outgoing MSE EOF→plaintext, forced encryption, explicit cancellation, deadline/no socket leak, successful RC4 without downgrade, explicit versus automatic scraper IP, bare tracker IP and the existing cancellation/Range behavior. Four negative controls deliberately restore the corresponding defects and fail as expected. The deadline case passes 30 repetitions. All use local/in-memory connections, with no public announces. Evidence: `engine-patches/checks/mumpa2-regressions.log`, `mumpa2-negative-controls.log`.
- The exact torrent dependency ZIP is hash-locked and unpacked into fresh source trees; the original TorrServer module files remain unchanged. `managed.mod` changes only the local torrent replacement. All four targets build with pinned Go/NDK, and two fresh Windows builds produce the same SHA256. Final binary hashes are in `engine-patches/managed-engine.lock.json`; matching complete patched source includes the fork and build instructions.
- Native Windows and Android API 35 x86_64 pass a new **outgoing** real BitTorrent fixture: a local tracker advertises a listening seeder, the first MSE connection is rejected, then the engine reconnects with the normal handshake and plays audio. Both observe one rejected encrypted and one accepted plaintext connection. Start times are **1451 / 1601 ms**, with **393,216 / 376,832 bytes** served out of **2,116,844**, while automatic full-track caching is still incomplete. Full SHA256, seek, HTTP Range, engine restart, offline playback and three peerless reader cancellations also pass. Android's real audio service is registered. Evidence: `test-output/windows-outgoing-mumpa2.log`, `android-outgoing-mumpa2.log`.
- Unit/widget suite: **75 passing**, one opt-in Jackett test skipped. The strict favorites option requires fresh HTTP source decoding, nonzero duration and at least 2500 ms of advancing playback; a bounded timeout fails that option. Source tracks are copied into an isolated library with cached paths cleared. `FAVORITES_SERVER_URL` permits only a loopback HTTP diagnostic server.
- **Real favorite playback still fails.** Against mumpa2 with added retrackers disabled, `Роженица в метро` and `Слава КПСС - Аниме Гангрейв` each report **0 active peers, 0 download speed, 0 decoded duration and 0 position**, and terminate after **45,347 / 45,144 ms**. The strict native test exits **1**. These are the actual existing favorite records and stored metainfo, not substitute test tracks. Evidence: `test-output/real-favorites-mumpa2-originals.json`, `real-favorites-mumpa2-originals.log`.
- Windows **1.1.4+6** and all three Android release APKs build. The packaged Windows app starts and preserves all four likes, library track IDs, RuTracker.org configuration, Jackett port/key and automatic caching; its managed FlareSolverr reports healthy. Windows ZIP size: **487,580,042 bytes**. ARM64/ARMv7/x86_64 APK sizes: **43,608,331 / 43,730,335 / 44,944,681 bytes**. Their engine hashes equal the locked raw binaries after the pinned NDK's `llvm-strip --strip-unneeded`; libmpv is present, Windows assets absent. The final x86_64 APK installs and launches on API 35 as **1.1.4 / versionCode 4006**, without an app AndroidRuntime crash. Evidence: `test-output/packaged-startup-1.1.4.json`, `apk-layout-1.1.4.json`, `android-release-startup-1.1.4.json`, and release build logs. Physical Android hardware remains untested.

Network observations are isolated from the protocol regressions. Both original announce URLs are public RuTracker hosts without passkeys/query credentials, and both metainfo files have no private flag. DNS and TCP port 80 connect. Public root GET replies vary with User-Agent; the ordinary reply is a static HTML page, not a peer list. Real announces with four different User-Agents receive no response. HTTPS to both tracker hosts fails the TLS handshake, while the RuTracker website and control HTTPS work. Three standard DHT bootstrap hosts (four IPv4 endpoints) do not answer correctly encoded FIND_NODE queries, including a BEP42-secure ID probe. A plain public UDP DNS request and an OpenTrackr UDP **connect** reply succeed; the separate favorite announce diagnostic to OpenTrackr has not been approved or executed. This does not prove general UDP blocking, a dead swarm, or VPN as the cause. Safe evidence is in `test-output/original-announce-agents-current.json`, `tracker-root-agent-current.json`, `public-transport-current.json`, `dht-find-node-current.json`, `dht-secure-current.json`, and `public-udp-current.json`.

At that inspection, split default routes used WireGuard. The original OpenTrackr diagnostic was rejected by automatic approval because it sends favorite info hashes and connection IP to a third-party tracker. The user subsequently refused VPN disconnection and explicitly authorized OpenTrackr; its completed results and the live route comparison are recorded in the 1.1.5 section above. No VPN, route or firewall changes were performed. A real favorite beginning playback remains an open acceptance criterion.

## 1.1.3 liked tracks, first audio and safe cancellation

Track-row loading indicators use centered square bounds (16 px), and the transport indicator stays square (18 px). Desktop and phone widget checks inspect actual rendered indicator dimensions while a liked torrent is pending. Screenshots: `test-output/liked-loading-1380.png` and `liked-loading-390.png`.

- **75 unit/widget tests pass**, with one ordinary-run opt-in native Jackett check skipped. Analysis reports no issues. Real HTTP tests establish that headers alone do not mean audio is ready, first-payload waits expire, a raw TCP peer sees disconnect, and probe cancellation preserves other HTTP clients. Controller regressions cover a liked track timing out and retrying with the same queue, intentional pause before the first position event, and an unresolved native open/stop lock without late playback.
- The managed `MatriX.145.2-mumpa1` source patch preserves the exact upstream source/modules, but forwards HTTP reads through `ReadContext(req.Context(), ...)`. Go regressions cover actual metadata-only torrent/cache readers, three local HTTP disconnects, and byte ranges. A negative control replacing that path with the original background-context read fails as expected (`managed-engine-negative-control.log`). A second build reproduces all four binary SHA256 values in `engine-patches/managed-engine.lock.json` (`managed-engine-reproducibility.log`). Matching patched source and build instructions are included in `TorrServer-MatriX.145.2-mumpa1-source.zip`.
- Final native Windows and Android API 35 x86_64 use the patched engine and a throttled original-audio BitTorrent swarm. Playback from **Liked tracks** advances beyond 500 ms in **1482 ms** on Windows and **1677 ms** on Android, with **376,832 / 2,116,844 bytes** (~18%) served on each. Both still have an incomplete automatic offline transfer. Complete WAV SHA256, seek/Range, real engine restart, and offline playback with engine/seeder stopped also pass. Android's native audio service is registered.
- After the healthy/offline checks, both platforms restart the engine with no available seeder and cancel **three** real first-byte probes. Each probe first creates an actual cache reader (`Readers > 0`) and cancellation returns `Readers` to **0**, without dropping/restarting the torrent between attempts. This detects the original server-side leak rather than only testing client cancellation. Logs: `windows-favorites-native.log`, `android-favorites-native.log`.
- The user's existing favorite records and metainfo are read into an **isolated** native Windows library. Two distinct public swarms (`Роженица в метро`, `Слава КПСС - Аниме Гангрейв`) do **not** play in the observed network. Their attempts end at **46,907 / 45,151 ms**, replace loading with an error, preserve the selected track and four-track queue, and render the Retry action. The native opt-in test passes its bounded-failure assertions; this does **not** establish successful public playback. Evidence: `real-favorites-native.log` and `real-favorites-result.json`.
- Windows 1.1.3+5 and all three Android release APKs build. The packaged Windows app starts with its own healthy FlareSolverr, preserves the Jackett key/port/RuTracker.org profile, all library track IDs and all **four** liked records, and keeps automatic caching enabled. The Windows ZIP is **487,579,417 bytes**; ARM64/ARMv7/x86_64 APKs are **43,608,331 / 43,730,315 / 44,942,157 bytes**. APK inspection verifies libmpv, excludes Windows assets, and reproduces each packaged engine hash by applying the pinned NDK's `llvm-strip --strip-unneeded` to the hash-locked source binary. The packaged Windows engine matches its lock directly. The final x86_64 release installs and launches on API 35 as version **1.1.3**, versionCode **4005**, without an AndroidRuntime crash. Evidence: `packaged-startup-1.1.3.json`, `apk-layout-1.1.3.json`, `windows-build-1.1.3.log` and `android-build-1.1.3.log`.

Independent tiny Range probes received zero audio bytes from both public swarms in 50 seconds, with no active peer connections and matching stored/server file identities. At inspection, IPv4 split default routes were assigned to an active WireGuard adapter. The user offered to switch VPN servers, but confirmation of the switch is unavailable; these observations do not prove VPN is the exact cause. No VPN, routes, firewall rules or user's library/settings are altered by these checks. Controlled native playback proves the application flow and engine, while reachable public P2P sources remain necessary for the user's favorite releases. Physical Android devices remain untested.

## 1.1.2 collection-first streaming and automatic offline copies

Catalog selection opens a persistent playlist containing the torrent's audio files. A track tap starts that track and uses the collection as the playback queue. Reopening one source preserves its playlist ID, edits and cached tags. No audio download is started merely by browsing metadata. Automatic complete-track caching defaults on, starts after the decoder opens and yields background downloads to the playing track with exact partial-file Range continuation.

- Widget/controller checks cover source selection without an import dialog, individual track playback, queue/playlist origin, adding to the current playlist without replacing playback, and desktop/phone widths. Repository checks cover collection persistence/edit preservation, explicit cache opt-out and loading defaults without overwriting a damaged source file. Download checks use real HTTP servers to verify priority interruption/resume, queued promotion, immediate pause/retry and bypassing an unrelated metadata wait.
- Native Windows and Android API 35 x86_64 pass the full fixture with an actual BitTorrent seeder throttled to 300 KiB/s. At the first advancing audio position (>500 ms), Windows started in **1475 ms** with **376,832 bytes** served, Android in **1688 ms** with **360,448 bytes** served, out of **2,116,844 bytes**. Each had an active incomplete automatic offline transfer and no completed cached path. This establishes streaming before a complete torrent/offline file, rather than fast playback of an already downloaded fixture.
- The automatic copy then completes with SHA-256 `f762a101b2d8ed4d05d83e073b81ad38b8b3dddfed8f398f8500f89bae0fcad6`. Both platforms additionally pass seek, exact HTTP Range, engine restart recovery and offline playback with the engine and seeder stopped; Android's native audio service is registered. Logs: `test-output/windows-collection-native.log` and `android-collection-native.log`.
- Final unit/widget suite: **68 passing**, one ordinary-run opt-in native Jackett test skipped. Static analysis: no issues. The authenticated Windows source check after packaged startup returns four `Ежемесячные` releases and opens `ДУШЕВНО И КРЕПКО` as a persistent playlist with eight tracks in **3059 ms**, rendering the collection page without a checkbox import dialog. Evidence: `test-output/real-source-collection-native.log` and `real-source-result.json`; public playback is not part of this source-only check.
- Final Windows 1.1.2+4 and three Android ABI releases build. Packaged Windows startup preserves the existing Jackett key/port/RuTracker.org profile, starts its own healthy FlareSolverr and confirms automatic track caching enabled. The Windows ZIP is 487,573,697 bytes; Android ARM64/ARMv7/x86_64 APKs are 43,605,327 / 43,724,167 / 44,935,789 bytes. APK inspection verifies native engine/player libraries and excludes Windows assets. The x86_64 release installs/launches on API 35 as versionCode 4004 without an AndroidRuntime crash. Evidence: `test-output/packaged-startup-1.1.2.json` and `apk-layout-1.1.2.json`.

The measured start times use an isolated original-content local swarm with controlled bandwidth. Public swarm start time depends on reachable peers; these measurements are not a promise for every tracker, format, network or physical phone. Physical Android devices have not been connected. Authenticated catalog checks use an isolated library and read the user's existing connection settings without altering that profile.

## 1.1.1 authenticated source opening and FlareSolverr

The user configured RuTracker.org successfully after the local FlareSolverr helper solved the actual site challenge (HTTP 200, challenge solved). RuTracker.RU was a different, already configured tracker and itself returned zero results for the original query. No credentials, challenge HTML, cookies or private tracker URLs are included in evidence.

- Unit/widget tests: 53 passing, one ordinary-run opt-in native Jackett test skipped. Added cases cover cancellation and stale search responses, metainfo deadlines, HTTP torrent preference, Cyrillic restoration, local Jackett config preservation and FlareSolverr integrity/lifecycle. The Windows Job Object test starts and terminates only its own parent and child.
- Authenticated native Windows search for `Ежемесячные` returns four real RuTracker.org releases. `(Rap, Hip-Hop) ежемесячные - ДУШЕВНО И КРЕПКО (без цензуры) - 2026, MP3, 192 kbps` opens in 2527 ms, exposes eight audio files and renders the native track selection dialog. A prior discography check exposed 493 audio files in 2804 ms. Evidence: `test-output/real-source-native.log` and `real-source-result.json`.
- The latest Windows native regression passes local playback/seek, real BitTorrent playback/seek, exact HTTP Range, complete download with the original WAV SHA-256, engine restart recovery and offline playback with both engine and seeder stopped. The local seeder serves 130 piece requests. Evidence: `test-output/windows-source-regression.log`.
- The same final native regression passes on Android API 35 x86_64, including the native audio service, with 130 served piece requests and matching offline SHA-256. Static analysis reports no issues. Evidence: `test-output/android-source-regression.log` and `source-final-analyze.log`. Physical Android devices remain untested.
- Public RuTracker playback is **not verified**: the additional opt-in playback attempt received no audio bytes and reached the decoder timeout. The engine had zero active peers and three pending peers; safe zero-payload TCP probes to those peer endpoints timed out. Tracker DNS and TCP ports 80/443 were reachable, while public HTTPS probes failed TLS handshakes. These observations do not prove the exact cause or that every public swarm fails. No firewall, proxy or VPN configuration was changed. Metadata opening/search passing does not establish public playback.

FlareSolverr's optional 378 MB Windows archive is extracted with file-backed streams off the UI thread and excluded from Android packages. The actual helper is started hidden, responds on loopback and is connected through Jackett's API while preserving its key/port/indexer profiles. Its enabled marker enables managed startup on the next app launch.

Final Windows 1.1.1+3 and Android ARM64/ARMv7/x86_64 release builds pass. The packaged Windows application was launched with the existing user profile: its own managed FlareSolverr responds healthy, the Jackett port/API key/indexer profiles are preserved and RuTracker.org remains configured (`test-output/packaged-startup-1.1.1.json`). The Windows ZIP is 487,587,907 bytes. Android APKs contain their respective libtorrserver/libmpv libraries, omit Windows engine/Jackett/FlareSolverr archives, and are 43,615,595 / 43,740,931 / 44,950,561 bytes. The final x86_64 release installs and launches on API 35 as version 1.1.1, versionCode 4003, without an AndroidRuntime crash. Release SAF/background media controls were verified in 1.1.0; the 1.1.1 native regression verifies playback and audio-service registration, without repeating that separate SAF UI run.

## 1.1 catalog and engine correction

The user reported that the actual release engine did not start and that a demo album with manually configured search did not meet the desired catalog flow. Jackett is now the default provider, including support for RuTracker.org configured with the user's own account. Windows bundles unchanged Jackett v0.24.2806 as a private, lazily started backend; Android can connect to an external Jackett. Direct RuTracker WebView access is an additional option. New installations do not receive demo tracks automatically.

- `flutter analyze`: no issues. `flutter test`: 41 passing unit/widget tests, with one opt-in native Jackett test skipped in the ordinary run. New cases cover joint UDP/TCP candidates and lifecycle failures; catalog parsers/CP1251/login verification; Jackett extraction/profile guards; caps verification, magnet redirects, metainfo downloads and invalid HTML.
- Opt-in real Windows Jackett test passed independently: bundled process serves caps, exposes RuTracker in the indexer inventory, uses private/update-disabled config, shuts down and omits its API key from startup diagnostics. This is not a test of authenticated RuTracker search.
- A real Windows WebView loaded six music categories, 29 top-level forums and 96 subforums in the music category. The next public forum displayed site verification. The probe confirmed the visible verification action; authenticated search/magnet retrieval still needs the user's own account and any site challenge.
- The actual Windows log showed UDP bind error 10013. TCP port zero can return consecutive ports inside an entire UDP exclusion block; unique random candidates now reserve TCP and UDP together, and the chosen address is passed to the native engine. No machine firewall rules were altered.
- Android uses AGP 8.13.2 / Gradle 8.13 with Kotlin 2.3.20. AGP 9 rejects the stable WebView plugin's old default ProGuard configuration; a supported build-tool version avoids modifying global package caches.

Final 1.1 native reruns pass on Windows and Android API 35 x86_64: local/torrent playback, seeking, exact HTTP Range, verified complete download, real engine restart and offline playback with engine and seeder stopped. Android also registers its native audio service. Each local seeder served 130 piece requests. The Windows native Jackett dashboard additionally opens, renders the actual Add indexer interface and closes correctly through WebView2. Logs: `test-output/windows-e2e-v11.log`, `android-e2e-v11-dds.log` and `jackett-ui-v11.log`.

Two initial Android test launches stalled while starting host DDS. After clearing the orphaned test DDS, the ordinary integration command completed with exit code zero. A diagnostic `--no-dds` run completed all app assertions but Flutter's golden-event proxy rejected its missing DDS stream; that diagnostic run is not counted as a passing test.

Windows release 1.1.0+2 and all three Android ABI release APKs build successfully. The installed x86_64 release APK (versionCode 4002) imports the original WAV through Android's real SAF file picker. After Home, system media commands produce PLAYING at 29 ms, PAUSED at 1249 ms and PLAYING at 1500 ms, with no app runtime exception. Delivered APKs contain their own `libtorrserver.so` and `libmpv.so`, exclude Windows assets, and the Windows ZIP includes the engine, Jackett archive and libmpv DLL. Physical Android devices and authenticated RuTracker account searches remain untested.

The following 1.0 verification record is retained as historical evidence.

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
