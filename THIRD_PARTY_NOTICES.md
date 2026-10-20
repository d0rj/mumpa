# Component notices and source locations

Mumpa application code is GPL-3.0; see `LICENSE`. Original generated demo audio, procedural artwork and branding are part of this project. Manrope is SIL Open Font License 1.1; its notice is in `assets/fonts/OFL.txt`. Dependency versions are in `pubspec.lock`, and Flutter's generated license registry is accessible in Settings → Licenses.

## Torrent engine

The packaged executables are TorrServer **MatriX.145.2-mumpa4**, GPL-3.0, built from upstream revision **bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9** with Mumpa's request-context cancellation, outgoing handshake fallback, tracker IP, explicit source-interface and active-reader chunk-priority patches. Copyright belongs to the TorrServer contributors and the authors of the included changes. The upstream license is retained.

- Source: https://github.com/YouROK/TorrServer/tree/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9
- Source archive: https://github.com/YouROK/TorrServer/archive/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9.zip
- Release/binary provenance: https://github.com/YouROK/TorrServer/releases/tag/MatriX.145.2
- Copyright/license: https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/LICENSE
- Corresponding patched source archive: `artifacts/TorrServer-MatriX.145.2-mumpa4-source.zip`.
- Checked overlays, toolchain versions and executable SHA-256: `engine-patches/managed-engine.lock.json` and `engine-patches/README.md`.
- Build and verification: `tools/build-managed-engine.ps1`, `tools/prepare-engines.ps1`.

The base torrent library is `github.com/tsynik/torrent v1.2.31`, pinned in the unchanged upstream `server/go.mod`/`go.sum`. Its exact module ZIP and checked overlays are unpacked into `server/mumpa-deps/torrent`; `managed.mod` replaces only that dependency with the local source. Its license is retained in the corresponding source archive. The patches bind blocking reads to the HTTP request context, retry a failed outgoing MSE handshake in plaintext when encryption is optional, and send bare tracker IP values only for explicit IP overrides. Cancellation, encryption policy and seek/range behavior are covered by Go regressions. Executables are compiled from the corresponding source and started as separate processes.

## Playback libraries

`media_kit` and its Flutter integration packages are MIT-licensed: https://github.com/media-kit/media-kit. Packaged native libraries are libmpv/FFmpeg builds supplied by the audio packages. Their upstream component licenses and source/build recipes accompany their source projects; the Flutter wrapper's MIT license does not replace native component licenses.

- Windows audio build: `mpv-dev-x86_64-20230924-git-652a1dd.7z`, provided by `media_kit_libs_windows_audio`; source/build recipes: https://github.com/media-kit/libmpv-win32-audio-build, release: https://github.com/media-kit/libmpv-win32-audio-build/releases/tag/2023-09-24.
- Android audio builds: `v1.1.8`, provided by `media_kit_libs_android_audio`; source/build recipes: https://github.com/media-kit/libmpv-android-audio-build, release: https://github.com/media-kit/libmpv-android-audio-build/releases/tag/v1.1.8.
- libmpv source/licenses: https://github.com/mpv-player/mpv.
- FFmpeg source/licenses: https://ffmpeg.org/legal.html and https://git.ffmpeg.org/ffmpeg.git.

Mumpa's DSP path explicitly loads the audio-only **mpv 0.41.0 / FFmpeg 8.1.1,
libmpv-r17** runtime distributed by `ales-drnz/mpv_audio_kit`. It includes the
`equalizer`, `loudnorm`, `aformat` and `pan` filters missing from the older
minimal runtime. The app continues to use the `media_kit` Dart transport and
Android helper integration; it does not use mpv_audio_kit's player/session APIs.

- Binary release and component manifest: https://github.com/ales-drnz/mpv_audio_kit/releases/tag/libmpv-r17
- Manifest: https://github.com/ales-drnz/mpv_audio_kit/releases/download/libmpv-r17/manifest.json
- Corresponding audio runtime build recipes/patches: https://github.com/ales-drnz/libmpv-scripts
- SHA-256 pins and native-assets bundling: `packages/mumpa_audio_runtime/hook/build.dart`.

The local bundling hook is Mumpa code. Native component licenses remain those
of mpv, FFmpeg and their dependencies; the Flutter wrapper's license does not
relicense those components. Binary checksums are verified before bundling.

For redistribution, keep this notice, the GPL text, dependency notices and corresponding source/build information alongside the application. The local release includes a Mumpa source archive and matching engine source archive. The distributed application package does not include third-party commercial music or remotely fetched album artwork.

## MusicBrainz metadata and Cover Art Archive

Music metadata is retrieved from [MusicBrainz](https://musicbrainz.org), maintained by the MetaBrainz Foundation and MusicBrainz contributors. Its [core data is released under CC0](https://musicbrainz.org/doc/About/Data_License). The displayed artist names, aliases, credits, MBIDs, recording durations and release facts belong to the core categories documented in the [database overview](https://musicbrainz.org/doc/MusicBrainz_Database).

MusicBrainz supplementary data has a separate [CC BY-NC-SA 3.0 license](https://creativecommons.org/licenses/by-nc-sa/3.0/). It includes annotations, user tags/ratings, derived statistics and search indexes. The CC0 designation for core fields does not apply to those categories. API responses cached in the user's profile retain the applicable upstream data licenses; Mumpa's GPL license does not relicense them. This release does not bundle a MusicBrainz database dump. See the [MusicBrainz data license](https://musicbrainz.org/doc/About/Data_License) for the core/supplementary distinction.

Album images are fetched at runtime from [Cover Art Archive](https://musicbrainz.org/doc/Cover_Art_Archive), the MusicBrainz/Internet Archive project, using its [public API](https://musicbrainz.org/doc/Cover_Art_Archive/API). Public access to an image does not establish an open license for that artwork. Rights remain with its respective artists, photographers, designers, labels or other rights holders; neither MusicBrainz core-data CC0 nor Mumpa's GPL license grants rights to the images. Cached images are separate from Mumpa's original procedural placeholders and are not included in the release archives.

The integration, caching behavior and search limits are described in [Music discovery](docs/MUSIC_DISCOVERY.md). MusicBrainz metadata identifies artists and recordings; it does not provide music audio or permission to redistribute recordings.

From 1.2.2, optional cover fallback reads public artist/album metadata from the
[Deezer API](https://developers.deezer.com/api) and small images from Deezer's
image CDN. The API is used only for artwork identification, never for audio or
previews. [Deezer's developer terms](https://cdn-content.dzcdn.net/pdf/CGU-developers.pdf)
apply to those services; metadata/artwork are not relicensed by Mumpa. Images
inside user-added torrent collections retain their respective holders' rights.
No external catalogue or user cover images are bundled with application builds.

## Public automatic catalogue services

Automatic music search uses the public Knaben API (https://knaben.org/api/v1/)
and RuTor music pages (https://rutor.info/). Optional magnet metadata lookup
uses Torrage's anonymous public download links (https://torrage.info/), addressed
only by infohash. These remote services and their catalogues are not bundled
with Mumpa. Torrage responses are checked against the requested content hash;
the page's JavaScript is not executed. Audio is transferred separately by the
bundled BitTorrent engine. Remote availability can vary independently of Mumpa.

## Other dependencies

Windows includes the unmodified **Jackett v0.24.2806** binaries as a separate managed process. Jackett is GPL-2.0; its LICENSE remains inside the bundled archive and extracted runtime. Matching source: https://github.com/Jackett/Jackett/tree/v0.24.2806; source archive: https://github.com/Jackett/Jackett/archive/refs/tags/v0.24.2806.zip. Binary provenance and pinned SHA-256 are in `tools/prepare-jackett.ps1`. The release includes the matching Jackett source archive alongside Mumpa and TorrServer sources.

`flutter_inappwebview` (Apache-2.0), `html`, `enough_convert` and `archive` retain their upstream licenses; their versioned notices are recorded in Flutter's license registry. Windows native browser uses the installed Microsoft Edge WebView2 runtime.

Windows applies two checked shutdown overlays to **flutter_inappwebview_windows
0.6.0** (Apache-2.0). The exact upstream package archive is pinned by
`pubspec.lock`; the two source SHA256 values and replacements are retained in
`windows/plugin_patches`. Patched translation units are generated in the build
directory. The changes release browser/composition owners and finish the
current-thread DispatcherQueue before COM teardown. Original component notices
remain in Flutter's license assets. Matching source:
https://pub.dev/packages/flutter_inappwebview_windows/versions/0.6.0.

Flutter (BSD-3-Clause): https://github.com/flutter/flutter. `audio_service`, `audio_session`, `file_picker`, `path_provider`, `path`, `crypto`, `http`, `audio_metadata_reader` and `xml` retain their respective package licenses. Exact versions and transitive packages are recorded by `pubspec.lock`; notices are included in Flutter's `NOTICES` asset.

## Optional Windows challenge helper

Windows bundles **FlareSolverr v3.5.2**, MIT License, Copyright (c) 2026 Diego Heras and contributors. Its complete license is retained in `assets/flaresolverr/LICENSE.txt`. Matching source revision: `93125d6ea6956906c8dfa29e169b2dc67d993dc3`; source archive is included in `artifacts/sources/FlareSolverr-v3.5.2-source.zip` for redistribution. The runtime archive omits only Chromium's standalone `interactive_ui_tests.exe` test runner; all other ZIP entries retain their original compressed bytes and metadata. FlareSolverr and its browser/runtime files are unchanged. `tools/prune-flaresolverr.mjs` documents the transformation and verifies the upstream SHA-256; installation verifies the derived runtime SHA-256.

- Source: https://github.com/FlareSolverr/FlareSolverr/tree/93125d6ea6956906c8dfa29e169b2dc67d993dc3
- Release: https://github.com/FlareSolverr/FlareSolverr/releases/tag/v3.5.2
- Binary SHA-256: `309abd7c821546325ae6c509b40d969c5e39034be2314d21b3f5e0517feda7a7`.
- Source ZIP SHA-256: `cfd9797fa59f43bba74820d0215945fa233fdd5c07377b66f4390b89c93167f1`.
- Downloads and verification: `tools/prepare-flaresolverr.ps1`.

The separate optional process includes Python, Chromium and upstream Python dependencies. Their package notices remain inside the unmodified archive/runtime. Chromium uses multiple BSD/MIT and other component licenses; its source is https://chromium.googlesource.com/chromium/src. The matching upstream FlareSolverr build recipe pins Windows Chromium snapshot revision **1681099** (`src/build_package.py`). ChromeDriver is obtained from Google's official Chrome for Testing distribution by upstream startup and retained only inside Mumpa's isolated helper profile; source/build information: https://chromium.googlesource.com/chromium/src/+/main/chrome/test/chromedriver/ and https://googlechromelabs.github.io/chrome-for-testing/.

## Development skills

Architecture and responsive-layout guidance was read from the upstream `flutter/skills` repository: https://github.com/flutter/skills. The two skill files are retained in `dev-skills`; they are development documentation, not application runtime dependencies.
