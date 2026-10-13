# Mumpa verification — 2026-10-13

## Windows installation and app updates 1.2.14+22

- Installed in the user's `%LOCALAPPDATA%/Programs/Mumpa/current`, registered
  in HKCU uninstall entries and the Start menu. `Get-StartApps` reports Mumpa;
  the shortcut targets the installed executable. The user confirmed that the
  actual library opened. The installed process responds with title Mumpa.
- **402 unit/widget tests passed**, three opt-in tests skipped. Analysis and
  formatting passed. The release publisher's **28 tests passed**.
- Installer fixture checks passed: initial install, replace, previous version,
  deliberate failure after file promotion and rollback, traversal rejection,
  SHA-256 rejection, and matching packaged helper scripts.
- The private GitHub release BUILD/SHA256 metadata was read using the host's
  existing `gh` credentials in the opt-in headless test. Downloaded package
  corruption, truncated bytes, retry, cached package, and changed files before
  installation were verified with isolated fixtures. The private → public
  transition test checks that public download makes no further CLI calls.
- Windows x64 and Android ARM64/ARMv7/x86_64 releases built. Android supports
  the system APK installer and scoped FileProvider; a physical Android install
  has not been tested. Existing CI debug-key signing remains incompatible
  across different ephemeral keys.
- A full live download of the 338 MB GitHub Windows ZIP was interrupted while
  diagnosing a slow transfer. It is **not** reported as a passed full remote
  download. An earlier native test-only window was closed; the installed app
  was then opened and confirmed by the user. Release builds ran sequentially
  after a concurrent integration test changed Android plugin registration.
- Evidence: `test-output/installed-windows-1.2.14.json`,
  `test-output/live-release-check/result.json`, `test-output/updates-full-tests.log`,
  `test-output/updates-android-build.log`, and isolated `test-output/install-test-*`.
  [Installation and update protocol](APP_UPDATES.md).

## Track → album → source collection navigation

- Track lists have a clickable album name on desktop and a `Перейти к альбому`
  menu action at every width. The compact/desktop player bar, full player and
  queue also link to the track's album. Player sheets close on navigation.
- The selected or playing version opens the album from its own torrent hash;
  other releases with the same artist/title stay separate. Local albums stay
  local. Current library metadata takes precedence over stale track objects.
- Album headers link to their actual source collections using both torrent
  hash and track membership. Ordinary playlists do not become parent
  collections. A library album containing multiple releases exposes all of
  its source collections; deleted collections disappear from the links.
- 17 new tests cover 320/390/1200 px, direct links/menus, player/queue navigation,
  source identity, preferred/playing variants, Back, metadata refresh, deletion,
  and unchanged playback/queue. Existing playback tests now tap track titles
  explicitly because an album name has its own navigation action.
- All 389 unit/widget tests passed; two existing opt-in tests skipped.
  `flutter analyze --no-pub lib test integration_test` and formatting passed.
  Evidence: `test-output/album-navigation-full-tests.log`,
  `album-navigation-analyze.log` and `album-navigation-*.png`.
- Responsive previews use the application's Manrope and MaterialIcons fonts;
  desktop and mobile album headers were visually inspected. Playback checks
  use the fake backend and cached fixtures without starting the torrent engine.
- Windows x64 release and Android ARM64/ARMv7/x86_64 release APKs built
  successfully; Android debug symbols are present. Build logs:
  `test-output/album-navigation-windows-build.log` and
  `album-navigation-android-build.log`. These are local builds of 1.2.13+21;
  no new release was published and no physical device was used.

## 1.2.13 search Back restoration

- Reproduced the blank search page after scrolling search results, opening an
  album, starting playback and pressing Back. The search options ExpansionTile
  inherited the same PageStorage identifier as the page's scroll position;
  rebuilding it tried to cast the stored double to bool.
- A dedicated PageStorageKey for the search options separates its expansion
  flag from the scroll offset. Navigation snapshots and playback are unchanged.
- Four regression cases cover 390/1200 px and expanded/collapsed options:
  preserved query, source results, scroll position, painted/clickable content,
  expansion state/toggling and continuing playback through the fake backend.
  The original code fails with `double is not a subtype of bool?`.
- 372 unit/widget tests passed; two existing opt-in tests skipped. Static
  analysis passed for lib/test/integration_test. Evidence:
  test-output/search-back-before.log, search-back-tests.log,
  search-back-full-tests.log and search-back-analyze.log.
- Windows x64 and Android ARM64/ARMv7/x86_64 release builds passed as
  1.2.13+21; Android symbols are retained. Packages and SHA-256 manifest are in
  artifacts/release-1.2.13. Build logs: search-back-windows-build.log and
  search-back-android-build.log; package checks: search-back-packages.json.
- Playback in the navigation regression uses an isolated fake decoder. This
  change has not been exercised on a physical Android device or a public swarm.

## 1.2.12 known track versions

- 368 unit/widget tests passed (two existing opt-in tests skipped). Analyzer
  passed for lib/test/integration_test. New checks cover conservative matching,
  censorship/format variants, duration partitions, 10k-copy scaling, defaults,
  split/rejoin, metadata invalidation, grouped favorites, and 320/1200 px UI.
- Isolated Windows debug integration passed with real libmpv: the popup played
  the chosen 21-second file; cover play started the 20-second default; the queue
  retained one version per song, saved playlist IDs stayed unchanged, and no
  network/engine requests occurred. Row/picker screenshots were inspected.
- Read-only production metadata audit: 9,501 files, 8,933 displayed groups,
  391 groups with multiple known files. Preparation/grouping took 450 ms in this
  native debug run. Only 26 files had known durations: these are candidate
  metadata matches, not acoustically verified duplicate counts. Different-album
  intro/outro titles remain separate. The production JSON stayed identical.
- Windows x64 release and Android ARM64/ARMv7/x86_64 releases built as
  1.2.12+20 with separate Android symbols. No dependency/runtime upgrades.
- Evidence: test-output/track-matching-tests.log, track-matching-native.log,
  track-matching-native.json, track-matching-rows.png, track-matching-picker.png,
  track-matching-windows-build.log, track-matching-android-build.log.
- This verifies local Windows decoding/selection and Android compilation.
  Public torrent swarms and physical Android devices were not exercised.
  No remote publication was performed.

Rules and storage behavior: [TRACK_MATCHING.md](TRACK_MATCHING.md).

## 1.2.11 Android package size

The baseline is a fresh ordinary release build of 1.2.10+18 with the same
Flutter/Gradle/NDK and split ABIs, rather than a debug APK or a universal APK.
The final build is 1.2.11+19:

| APK | Before, bytes | After, bytes | Reduction |
| --- | ---: | ---: | ---: |
| ARM64 | 43,864,979 | 42,547,833 | 1,317,146 / 3.00% |
| ARMv7 | 44,006,943 | 42,604,845 | 1,402,098 / 3.19% |
| x86_64 | 45,211,789 | 43,867,835 | 1,343,954 / 2.97% |

- The unused Cupertino Icons dependency/font is removed. No other locked
  dependency changes. All displayed icons still use the existing Material set.
- Demo assets have a `.wav.bin` package suffix so Android's default WAV
  no-compress rule no longer applies. Their **decoded bytes and SHA-256 are
  identical**, and `createApplication(demo: true)` still writes the original
  `.wav` filenames. No audio conversion or quality change occurs. New installs
  still do not seed demos. The native fixture confirms the original first WAV
  hash `f762a101b2d8ed4d05d83e073b81ad38b8b3dddfed8f398f8500f89bae0fcad6`.
- `tools/build-android.ps1` uses `--split-debug-info`, without obfuscation.
  Each matching SYMBOLS file is retained in an additional release ZIP; publisher
  preflight requires that ZIP. All three **ELF build IDs match** their compiled
  `libapp.so`. A build experiment with only this flag saves 660,180 / 745,136 /
  686,992 bytes for ARM64/ARMv7/x86_64. This is Flutter's
  [documented size option](https://docs.flutter.dev/perf/app-size#reducing-app-size).
- All other native libraries, including **TorrServer, Flutter and libmpv**, and
  `classes.dex` match the baseline byte for byte. Engine source binaries retain
  their locked hashes. All three APKs pass CRC, APK signature, alignment,
  ABI/version/minSdk checks. Windows helper archives remain excluded. Evidence:
  `test-output/android-size-verification-1.2.11.json`,
  `android-symbols-verification-1.2.11.json`,
  `android-platform-verification-1.2.11.json` and release build logs.
- **351 unit/widget tests** pass, two opt-in live checks are skipped; analyzer,
  formatting for `lib test`, **28 release publisher tests**, Actionlint, Node
  syntax, PowerShell parsing and `git diff --check` pass. Windows release builds
  with the new asset lookup as well. Logs: `flutter-tests-1.2.11.log`,
  `analyze-1.2.11.log`, `release-publication-tests-1.2.11.log`,
  `windows-build-1.2.11.log`.
- Native **Android API 35 x86_64 profile** integration passes local playback and
  seek; early torrent audio, liked torrent playback, HTTP Range; complete offline
  download; engine restart; reader cancellation on peerless retries; offline
  playback with engine/seeder stopped; native audio-service registration. First
  streamed audio is observed at 1,401 ms, with 376,832 bytes transferred, through
  the local original-content seeder. This is fixture evidence, not a public-swarm
  latency claim. Log: `android-native-1.2.11.log`.
- The actual optimized **release x86_64 APK** installs and renders the normal
  app on the isolated emulator as 1.2.11 / versionCode 4019. Its extracted engine
  hash matches the packaged engine, and no AndroidRuntime/Flutter exception is
  observed. Screenshot: `android-release-1.2.11.png`. ARM64/ARMv7 runtime on
  physical phones, store download/install size and public torrents are not
  retested. No claim of universal zero regressions follows from these checks.

R8, resource shrinking, icon tree shaking and ABI splits were already enabled.
The largest APK entry remains the compressed torrent engine (~24 MB on ARM64).
Codecs, engine APIs and supported Android versions are retained. Native-library
extraction stays enabled because `MainActivity` executes the engine from
`applicationInfo.nativeLibraryDir`; changing that setting can break playback.

## 1.2.10 performance, file organization and Windows package size

- **351 unit/widget tests pass**, two opt-in live checks remain skipped.
  Analyzer and Dart formatting pass. New checks preserve timeline updates while
  retaining the existing player artwork widget, and verify volume/pause updates
  at phone and desktop widths. Browsing checks cover cache invalidation after
  queries, favorites, playlist membership, metadata replacement and removal.
  Existing navigation, favorite chronology, queue/repeat/shuffle, radio,
  persistence, downloads and artwork regressions pass. Logs:
  `test-output/flutter-tests-1.2.10.log`, `analyze-1.2.10.log`.
- On the same 10,000-track synthetic fixture, 100 warmed getter reads measured:

  | View | Before, ms | After, ms |
  | --- | ---: | ---: |
  | Selected album | 960.845 | 0.042 |
  | Recent albums | 974.494 | 0.673 |
  | Library section results | 97.575 | 0.090 |
  | Favorite section results | 66.838 | 0.041 |

  These are diagnostic Dart test timings for repeated unchanged views, not
  cold startup, network latency or a promised frame rate. Evidence:
  `test-output/browsing-before.log`, `flutter-tests-1.2.10.log`.
- Native **Windows profile** search uses a temporary copy of the current real
  library plus one fixture track: **9,502 tracks**. Eleven edits plus their next
  frame measure **21.5–56.4 ms**. Ten position updates perform 60 ID lookups and
  do not rebuild visible track rows. Native **libmpv** separately verifies natural
  track completion, prepared radio continuation, unchanged playlist membership
  and pause retained for four seconds, with zero external HTTP/engine calls.
  The Flutter driver reports success; its existing integration-plugin warning
  is retained in the logs. Evidence: `windows-search-1.2.10.log`,
  `windows-radio-1.2.10.log`. The radio fixture still writes a legacy 1.2.9-named
  report; the fresh 1.2.10 build/driver log identifies this run.
- The prepared FlareSolverr ZIP is **228,891,351 bytes**, down from
  **378,135,875 bytes**, by omitting only Chromium's standalone test executable.
  All **410 retained entries** have identical decoded SHA-256, CRC, sizes,
  timestamps and attributes. The raw compressed records are copied intact.
  The reduced helper starts, returns HTTP 200 health, and its real bundled
  Chromium returns HTTP 200 with the expected local HTML response in **17.6 s**.
  Evidence: `flaresolverr-runtime-verification.json`,
  `flaresolverr-runtime-smoke.json` and `.log` under `test-output`.
  Upstream references: [FlareSolverr's pinned browser launcher](https://github.com/FlareSolverr/FlareSolverr/blob/93125d6ea6956906c8dfa29e169b2dc67d993dc3/src/utils.py#L217),
  [Chromium test targets](https://chromium.googlesource.com/chromium/src/+/main/chrome/test/BUILD.gn).
- The final local **Windows release 1.2.10+18** builds. Its ZIP is
  **338,849,067 bytes**, compared with **487,979,054 bytes** for local 1.2.9:
  **149,129,987 bytes / 30.56% smaller**. ZIP CRCs, executable version and bundled
  runtime SHA-256 pass; the original large helper archive is absent. Evidence:
  `windows-build-1.2.10.log`, `package-verification-1.2.10.json`.
- Page/metadata file extraction preserves the original non-whitespace content;
  public imports and private Dart library boundaries are preserved by `part`.
  Architecture/source notices document the runtime transformation. **27 release
  publisher tests**, Actionlint 1.7.12, Node syntax, PowerShell parsing and
  `git diff --check` pass. This change makes no Android size-reduction claim:
  the Windows helper was already platform-filtered out of APKs. Hosted Windows
  and Android release checks/build/publication are started separately and are
  deliberately not monitored to completion. Physical Android and public torrent
  networks are not retested for this optimization increment.

## 1.2.9 playlist radio

- **348 unit/widget tests pass**, two opt-in live checks remain skipped.
  `flutter analyze --no-pub lib test integration_test` reports no issues.
  Radio tests cover early preparation, immediate playback of the first ready
  candidate during a slow refill, failed swarm/decoder skipping, normalized
  duplicates/recent plays, source cooldown, cache reuse, native file IDs,
  recoverable direct-catalogue magnets, paused restoration and saved opt-in.
  Cancellation includes pause/Stop/sleep/Repeat/disable/queue replacement both
  during preparation and a pending decoder open. The settings and queue layouts
  pass at 320 and 1200 px. Evidence: `test-output/flutter-tests-1.2.9.log`,
  `analyze-1.2.9.log`.
- An isolated **native Windows/libmpv** integration fixture naturally finishes
  its original three-second WAV and starts a preflighted radio track. The
  playlist remains unchanged, pause remains paused for four seconds, and no
  external HTTP/torrent-engine request occurs. Evidence:
  `test-output/windows-radio-1.2.9.log`, `native-radio-1.2.9.json`;
  fixture: `integration_test/playlist_radio_test.dart`, opt-in define
  `PLAYLIST_RADIO_TEST=true`. This verifies native local continuation; it does
  not establish live discovery coverage, public peer reachability or audible
  similarity. Network failures and Torznab/direct-catalogue discovery use
  deterministic mocked tests. A physical Android device was not tested.
- Windows x64 and Android ARM64/ARMv7/x86_64 release builds target **1.2.9+17**.
  Engine source/binaries are unchanged (`MatriX.145.2-mumpa4`); Android uses the
  existing local development signing key. Release logs:
  `test-output/windows-build-1.2.9.log`, `android-build-1.2.9.log`.
  Windows versions and APK signatures/ABI version codes (2017/1017/4017),
  ZIP/APK CRCs and manifest sizes/SHA-256 pass. Pinned engine inputs match the
  lock; packaged Android engines match Gradle's stripped outputs and 1.2.8.
  Package verification is recorded in `test-output/package-verification-1.2.9.json`.
  Radio defaults off; existing library, queue, favorites and source settings
  use their prior persistence formats plus optional radio fields.
- The previous Windows app completed its normal save/service shutdown; the
  packaged **1.2.9+17** app opened a responding Mumpa window. The real profile
  retains **9,397 tracks / 11 playlists / 34 likes**. Track IDs, playlist and
  favorite contents, queue order/selection and non-playback settings match
  their prior hashes; autoplay remains off. Evidence: `test-output/launch-1.2.9.json`,
  `profile-preservation-1.2.9.json`. Credentials were neither printed nor stored
  in these evidence files. This is persistence/startup evidence, not a live
  recommendation or public-swarm listening test.
- Full behaviour and bounds: [PLAYLIST_RADIO.md](PLAYLIST_RADIO.md).

## 1.2.8 search performance, artist pages and settings

- **321 unit/widget tests pass**, two opt-in network checks are skipped.
  `flutter analyze --no-pub lib test integration_test` reports no issues;
  `lib`/`test` and the new native test/driver pass Dart formatting.
  Coverage includes immutable search snapshots and ID indexes, concurrent
  collection removal during index preparation, liked artist tracks first,
  queue order, settings subpages/navigation/drafts, recommendation cancellation,
  authoritative artist IDs, disk cache restart/expiry/clear and response limits.
  Evidence: `test-output/flutter-tests-1.2.8.log`, `analyze-1.2.8.log`,
  `format-1.2.8.log`.
- A read-only benchmark of the existing **9,397-track** profile measured
  three local-search scans at **1.36–1.42 seconds before / 7–19 ms after**
  indexing. Ten thousand last-track ID lookups dropped from **1.17 seconds
  to 6.7 ms**. Search normalization runs in an isolate before publication;
  immutable metadata reuses weak indexes. Large profile JSON encoding also runs
  outside the UI isolate, while atomic writes retain their serialized order.
  Evidence: `test-output/search-performance-before.log`,
  `live-metadata-performance-1.2.8.log`. These are operation timings, not frames.
- A **native Windows profile-mode** integration check types each character of
  `Ежемесячные` into the actual global field with the real metadata in an isolated
  temporary library. Editing plus the next frame takes **21–39 ms**, including
  the first character. The full list remains lazy; ten playback-position ticks
  produce **zero row transport notifications** and no per-row ID resolution.
  Evidence: `test-output/windows-search-responsiveness-1.2.8.log`.
  Audio is FakeAudioBackend, external HTTP/engine calls are disabled. This does
  not measure Jackett response time, torrent throughput or physical Android UI.
- Artist and settings layouts are checked at **320/1200 px**. An artist page
  starts with that artist's newest liked tracks, then albums/discography/tracks.
  Opening, searching and playing the liked subset preserve the full subset queue.
  Settings build only the selected category: sources, torrent engine, downloads,
  metadata/cache, Windows player or about; Back and field drafts are preserved.
- The no-key **ListenBrainz Labs** query for `Ежемесячные` returns HTTP 200 and
  seven similar artists. A fresh repository reads the same result with HTTP
  disabled. Recommendations load separately after MusicBrainz identification,
  use the shared size-limited FIFO metadata cache (7 days; empty results 1 day)
  and remain optional on error. Mocked tests verify stale-page rejection,
  independent cancellation, request deduplication, size/schema limits and cache
  clearing. Source comparison and API limitations:
  `docs/SIMILAR_ARTISTS_RESEARCH.md`. Evidence:
  `test-output/live-metadata-performance-1.2.8.log`.
- Windows x64 and Android ARM64/ARMv7/x86_64 release builds succeed for
  **1.2.8+16**. Windows ProductVersion/FileVersion match; all four unchanged
  engine inputs match the pinned `MatriX.145.2-mumpa4` SHA-256 lock. Android
  uses the existing local development key. Evidence:
  `test-output/windows-build-1.2.8.log`, `android-build-1.2.8.log`.
  All three APK signatures/ABI version codes are verified; packaged ZIP/APKs
  pass CRC and manifest SHA-256/size checks. The prior 1.2.7 process exits via
  the normal save/shutdown handshake; packaged 1.2.8 opens a responding window.
  Evidence: `test-output/package-verification-1.2.8.json`, `launch-1.2.8.json`.
  A physical Android device, native audio decoding and public torrents were
  not retested for these UI/metadata changes.

## Automatic GitHub Release publication

- **27 Node 22 tests pass** using isolated original package fixtures and a
  mocked GitHub API. They cover first publication, exact commit/run/version
  binding, corrupt or missing packages, authorization failures, streamed
  uploads, server size/digest checks, recovery of a partial draft through the
  paginated release list, lightweight/annotated tags, tag conflicts and
  immutable published assets. Missing tags use the exact Git ref endpoint;
  the tests reproduce the commit endpoint's actual HTTP 422 behavior.
  Evidence: `test-output/release-publication-tests.log`.
- Actionlint 1.7.12, Node syntax checking, the PowerShell parser and
  `git diff --check` pass. The real nine local 1.2.7 ZIP/APK packages pass the
  publisher's size/SHA-256 preflight, producing eleven flat release assets
  including `BUILD.json` and `SHA256.json`, without HTTP requests.
  Evidence: `test-output/release-actionlint.log`,
  `release-plan-1.2.7.log`.
- Publication is a separate Linux job with `contents: write`, after the
  existing checks and Windows/Android build. Manual launches and accepted
  `main` PR merges are the only release triggers; no push trigger was added.
  Fork merges check out only the accepted merge SHA. Full hosted publication
  and GitHub Release assets are pending an authorized push/manual run; the
  mock tests and local preflight do not establish a successful hosted release.

## 1.2.7 newest favorite additions first

- **289 unit/widget tests pass**, one opt-in Jackett check is skipped,
  `flutter analyze --no-pub lib test integration_test` reports no issues,
  and formatting passes for `lib`/`test`. Evidence:
  `test-output/unit-1.2.7.log`, `analyze-1.2.7.log`.
- Four repository regressions verify addition order independently of import,
  album titles and playlist creation; unlike/re-like, metadata/playlist edits,
  deletions, restart and legacy JSON with missing references retain the correct
  order. Existing album-selection and playlist-favorite tests pass alongside
  them. Evidence: `test-output/favorites-order-targeted-1.2.7.log`.
- Two UI scenarios at **320/1200 px** verify the actual reading order of album
  cards, playlist/source-collection cards and track rows. Local favorite search
  retains category order; clearing it and clicking **Listen** builds the same
  newest-first track queue. Temporary local files and FakeAudioBackend are used,
  with assertions for **0 HTTP / 0 engine requests**. Evidence:
  `test-output/favorites-order-ui-1.2.7.log`. This change concerns saved ordering;
  native audio/public-torrent tests and physical Android runtime checks were
  not repeated.
- Windows x64 and Android ARM64/ARMv7/x86_64 release builds succeed for
  **1.2.7+15**. Windows executable product/file versions match; all four engine
  inputs match the existing pinned SHA-256 lock. APKs use the existing local
  development signing key. Build logs: `test-output/windows-build-1.2.7.log`,
  `android-build-1.2.7.log`.

## 1.2.6 editable playback queue

- **283 unit/widget tests pass**, one opt-in Jackett check is skipped, and
  `flutter analyze --no-pub lib test integration_test` reports no issues.
  Formatting passes for `lib`, `test` and the new native test. Evidence:
  `test-output/unit-1.2.6.log`, `analyze-1.2.6.log`.
- Ten new controller tests cover moving the current occurrence, crossings in
  both directions, duplicate tracks, next/previous, paused/pending playback,
  invalid moves, disk persistence, playlist origin, shuffle and legacy sessions
  without the new base-order field. Eight UI tests perform touch/mouse drags
  at **320/1200 px**, up/down menu actions with disabled bounds, and removal of
  one duplicate while the other remains movable. They verify the same selected
  occurrence and position with no additional open/stop/seek calls. Evidence:
  `test-output/queue-targeted-1.2.6.log`, `queue-ui-1.2.6.log`.
- The opt-in Windows native test uses **real libmpv** and five original local
  WAVs in a temporary library. Two Flutter mouse gestures on the real drag
  handles change occurrence order **[0,1,2,3,4] → [4,0,1,2,3] → [4,0,2,1,3]**.
  The selected occurrence stays the same at index 3. Its paused position is
  **2000 ms before / 1999 ms after**; decoder counters remain
  **open=1, stop=1, seek=1**. Real playback resumes to **2440 ms**, then Next
  opens the new successor and advances to **500 ms**. The test verifies
  **0 HTTP requests / 0 engine requests**. Evidence:
  `test-output/native-queue-reorder-1.2.6.log`, `queue-reorder-1.2.6.png`,
  `queue-reorder-1.2.6.json`. The production profile and public torrents are
  not accessed. Android touch behavior is checked at 320 px in widget tests;
  no physical Android runtime check was repeated.
- Windows x64 and Android ARM64/ARMv7/x86_64 release builds succeed for
  **1.2.6+14**. All four engine inputs match the existing pinned SHA-256 lock.
  Android uses the existing local development signing key. Build logs:
  `test-output/windows-build-1.2.6.log`, `android-build-1.2.6.log`.

## 1.2.5 parallel album downloads

- **265 unit/widget tests pass**, one opt-in Jackett check is skipped, and
  `flutter analyze --no-pub lib test integration_test` reports no issues.
  Formatting passes for `lib`, `test` and the new native test. Existing settings
  layouts remain covered at 320–1380 px. Evidence:
  `test-output/unit-1.2.5.log`, `analyze-1.2.5.log`.
- The shared scheduler defaults to **3 concurrent tracks**, with a persisted
  **1–6** setting under Offline and cache. Tests hold three real HTTP response
  bodies simultaneously while a fourth waits, then refill one slot without
  stopping neighboring transfers. Coverage includes deduplication, failures,
  immediate pause/retry with exact Range bytes, shutdown, priority with free/full
  slots, the sequential setting, and live concurrency changes **1→3→1** with
  persisted limits and byte-identical resumed files. Safety regressions verify
  shared 1 MiB quota reservations for known/unknown sizes, rejected overrun, finalization
  versus removal, preserved tags/favorites, app-owned deletion, and incomplete
  HTTP206 remaining a resumable partial.
- The opt-in Windows native test uses an isolated library and loopback HTTP
  server. Clicking **Download album** verifies three nonzero progress bars,
  fourth-track queueing,
  pause/resume through actual UI buttons while two neighbors remain active,
  **Range offset 49152**, and **4/4 exact 262144-byte original WAV files** by
  byte comparison and SHA-256. There are no external HTTP or engine requests;
  audio uses FakeAudioBackend. This proves download scheduling, HTTP transport
  and UI behavior, without claiming public-swarm throughput. Evidence:
  `test-output/native-parallel-downloads-1.2.5.log`,
  `parallel-downloads-1.2.5.png`, `parallel-downloads-1.2.5.json`.
- Windows x64 and Android ARM64/ARMv7/x86_64 release builds succeed for
  **1.2.5+13** with the same pinned engine inputs (all four SHA-256 values match
  the lock). APKs use the existing local development signing key. No physical
  Android runtime check was repeated for this scheduler change. Build logs:
  `test-output/windows-build-1.2.5.log`, `android-build-1.2.5.log`.

## 1.2.4 global and section search

- **251 unit/widget tests pass**, one opt-in Jackett check is skipped, and
  `flutter analyze --no-pub lib test integration_test` reports no issues.
  Formatting passes for `lib`, `test` and the new native test. New checks cover
  complete album/playlist results, exact favorite membership, artist and offline
  filters, independent queries and Back at 320/1200 px. Global-field tests cover
  stable focus/controller, selection and IME composition across notifications
  and resizing, Ctrl+K, one Enter request before debounce, ignored late replies,
  empty submissions and unconfigured indexers. Both artist-to-search actions
  restore the previous global query/mode on Back. Evidence:
  `test-output/unit-1.2.4.log`, `analyze-1.2.4.log`, `global-search-1.2.4.log`.
- The opt-in native Windows test copies the existing **Ежемесячные** collection
  into an isolated library, excluding settings and torrent access URLs. Searching
  the library returns **72 complete albums / 493 tracks**, **Лимбо: 6/6 tracks**
  with its existing real cover, and exactly the real **твои уши** file. Opening
  an album and Back retain the local query. Focusing the shared header does not
  navigate; typing opens Search while the same global field remains present.
  The test verifies **0 HTTP requests / 0 engine requests** and byte-identical
  production library contents afterward. Audio uses a fake backend because this
  check concerns search/navigation. Evidence:
  `test-output/native-local-search-1.2.4.log`, `real-local-search-1.2.4.png`.
- Windows x64 and Android ARM64/ARMv7/x86_64 release builds succeed for
  **1.2.4+12** with the existing pinned engine. APKs use the local development
  signing key. No physical Android runtime check was repeated; mobile layouts
  and keyboard actions are covered by the 320 px widget scenarios. Build logs:
  `test-output/windows-build-1.2.4.log`, `android-build-1.2.4.log`.

## 1.2.3 favorites for individual discography albums

- **222 unit/widget tests pass**, one opt-in Jackett check is skipped, and
  `flutter analyze --no-pub lib test integration_test` reports no issues.
  New persistence checks cover independent album/track/collection favorites,
  multiple discs, changed tags, another torrent edition, deleted files and
  backward-compatible profiles. Widget checks at 320/1200 px save an album
  directly from its card without opening it or playing audio, then open it
  from Favorites, play only its tracks and remove its favorite.
- The opt-in Windows native test reads the existing **Ежемесячные** discography
  into an isolated library without indexer credentials or network calls.
  It saves **Лимбо: 6 tracks out of 72 albums / 493 tracks**, reloads the library,
  opens the favorite and verifies native libmpv playback of the existing
  cached **твои уши** file with 1970 ms advancing position. The queue contains
  exactly the six album tracks. The source collection and individual tracks
  are not implicitly liked; removing the album favorite keeps all library
  tracks. This check establishes cached playback, not fresh swarm availability.
  The production library is read only. Evidence:
  `test-output/unit-1.2.3.log`, `analyze-1.2.3.log`,
  `native-album-favorites-1.2.3.log`, `real-favorite-album-1.2.3.png`.
- Windows x64 and Android ARM64/ARMv7/x86_64 release builds succeed for
  **1.2.3+11** using the existing pinned engine. APKs use the local development
  signing key. No Android device runtime check was repeated for this UI/library
  change; the narrow-layout widget scenario passes. Build logs:
  `test-output/windows-build-1.2.3.log`, `android-build-1.2.3.log`.

## 1.2.2 real artwork, Back, spelling correction and startup

- **216 unit/widget tests pass**, one opt-in Jackett test is skipped, and
  `flutter analyze --no-pub` reports no issues. New checks cover exact torrent
  cover paths and native file IDs, bounded/cancellable transfers, offline cache
  reuse, Deezer matching and transport failures, cache-generation races, decoded
  image revisions, navigation history, conservative query correction and native
  recording-variant import. Playing/enqueuing a file removed from a saved source
  playlist preserves that edit and its favorite. A 10,000-track restoration test
  requires one directory scan, two actual partial-file size reads and no engine
  calls; Windows path matching remains case insensitive. Evidence:
  `unit-final-1.2.2.log`, `analyze-final-1.2.2.log`.
- The native Windows artwork check uses the existing **Ежемесячные** collection:
  **72 albums / 493 tracks, 72 actual images retrieved and decoded**, no missing
  covers. Each album also has an unambiguously resolved physical image in the
  saved torrent. The first full public-network pass decoded 71 images; retry
  decoded the remaining image. The repeat after cache warming decoded all 72 in
  its first pass. Direct external fallback checks decode Deezer images for
  **Родничок** (34,733 bytes) and **Призраки Фантьета** (34,040 bytes). This is an
  image-transfer proof, not a full music-download proof. The test warms only the
  user artwork cache, **7,104,278 bytes / 217 entries**, and leaves the source
  library byte-for-byte unchanged. A restarted repository serves a cached image
  with both engine and HTTP factories disabled. Evidence:
  `artwork-native-1.2.2.log`, `artwork-native-startup-1.2.2.log`,
  `artwork-navigation-1.2.2.json`, `real-discography-covers-1.2.2.png`.
- A Win32 **XBUTTON1** down/up sent to the owned Flutter window invokes Back,
  returning from an album to its original collection entry and playlist context.
  UI history tests separately cover filters, results, artist state and repeated
  album/playlist routes. The native check temporarily enables live device events
  only for its owned window.
- The configured RuTracker.org Jackett endpoint returns **0** releases for
  **Ежемесечные**, then **4** for **Ежемесячные**, including the same 72-release
  discography. The wrapper's tested rule is literal query first, then at most one
  unambiguous corrected request. Jackett still searches release metadata;
  correction does not create a complete per-track index. Evidence:
  `typo-live-1.2.2.json`.
- The read-only firewall diagnosis finds executable-specific QueryUser filters
  for changing portable Mumpa paths. The UI-process TCP/UDP port probe now binds
  **127.0.0.1**; actual torrent listeners remain in the native engine at its stable
  profile path. Socket tests verify both loopback probes, conflicts and cleanup.
  No firewall rule, VPN or system route was modified. Evidence:
  `firewall-listener-diagnosis.json`; details in `NETWORK_DIAGNOSTICS.md`.
- **MatriX.145.2-mumpa4** passes **28 focused Go tests**. A slow original-content
  peer-wire fixture proves that an image beginning in block 62 is readable in
  about 302 ms before whole-piece completion, followed by normal SHA-1 completion.
  Restoring the upstream block order fails the same test. Only chunk order within
  the selected current piece changes; upstream multi-piece ordering and already
  dispatched requests remain intact. Two real public covers now transfer in
  **12.176 / 24.190 seconds**, compared with neither completing during the older
  60-second probe. Artwork jobs have a 45-second bound; public metadata runs in
  parallel and may show an image first. Evidence: `engine-build-1.2.2.log`,
  `reader-chunks-regression.log`, `reader-chunks-negative.log`,
  `artwork-http-diagnosis.json`.
- Windows native outgoing peer-wire verification passes with mumpa4: original
  audio starts in **1,496 ms**, with **393,216 / 2,116,844 bytes** transferred at
  first playback. MSE fallback, favorites, full automatic offline download with
  expected SHA256, HTTP Range/seek, engine restart, offline playback and three
  peerless cancellation attempts pass. Evidence: `windows-peer-1.2.2.log`.
- The same original-content outgoing fixture passes on the own **Android API 35
  x86_64 emulator**: sound starts in **1,636 ms**, with **360,448 / 2,116,844
  bytes** transferred. MSE fallback, full SHA256 cache, Range/seek, restart,
  offline playback and reader cancellation pass; the Android audio service is
  registered. Physical Android hardware is untested. Flutter replaced the
  emulator's older release package because its release ABI version code exceeds
  the debug test version code. Evidence: `android-peer-1.2.2.log`.
- The white artwork-test window was caused by waiting for its network probes
  before `pumpWidget`; the fixture now presents the collection first. Production
  bootstrap presents its first frame before native decoder/library initialization.
  Another production bottleneck was checking almost 8,000 absent `.part` files
  individually; restoration now scans the download directory once. Managed
  search helpers remain asynchronous.
- Windows **1.2.2+10** and all three Android release APKs build. Raw and packaged
  stripped engine hashes match the promoted mumpa4 lock; each APK includes libmpv
  and excludes Windows/helper assets. APK sizes are **43,784,043 / 43,921,155 /
  45,126,941 bytes** for ARM64 / ARMv7 / x86_64. The x86_64 release installs and
  launches as **1.2.2 / versionCode 4010** on the own API 35 emulator, with no app
  runtime crash. Evidence: `windows-release-1.2.2.log`,
  `android-release-1.2.2.log`, `apk-layout-1.2.2.json`,
  `android-release-startup-1.2.2.json`.
- The packaged Windows application starts twice against the current real profile.
  Its first rendered dark frame appears in **439 / 262 ms**, and the full sidebar
  interface in **566 / 396 ms**. Jackett/FlareSolverr become healthy separately in
  **15.111 / 11.816 seconds**, without delaying that interface. Native close hides
  to tray, restore works, orderly quit exits **0** and stops managed helpers.
  Restart preserves the current **11 favorites**, playlist favorites, library
  IDs, exact playlist membership/order, original queue, Jackett port/key,
  RuTracker.org configuration, automatic caching, **256 MB** metadata cache limit
  and the authorized **Беспроводная сеть** torrent interface. One final packaged
  instance remains open. Evidence: `packaged-startup-1.2.2.json`. Read-only rules
  inspection finds **no firewall rule or QueryUser filter for the new portable
  1.2.2 executable path**: `firewall-release-1.2.2.json`.

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
