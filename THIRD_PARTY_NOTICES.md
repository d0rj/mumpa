# Component notices and source locations

Mumpa application code is GPL-3.0; see `LICENSE`. Original generated demo audio, procedural artwork and branding are part of this project. Manrope is SIL Open Font License 1.1; its notice is in `assets/fonts/OFL.txt`. Dependency versions are in `pubspec.lock`, and Flutter's generated license registry is accessible in Settings → Licenses.

## Torrent engine

The packaged executables are TorrServer **MatriX.145.2-mumpa1**, GPL-3.0, built from upstream revision **bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9** with Mumpa's request-context cancellation patch. Copyright belongs to the TorrServer contributors and the authors of the included changes. The upstream license is retained.

- Source: https://github.com/YouROK/TorrServer/tree/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9
- Source archive: https://github.com/YouROK/TorrServer/archive/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9.zip
- Release/binary provenance: https://github.com/YouROK/TorrServer/releases/tag/MatriX.145.2
- Copyright/license: https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/LICENSE
- Corresponding patched source archive: `artifacts/TorrServer-MatriX.145.2-mumpa1-source.zip`.
- Checked overlays, toolchain versions and executable SHA-256: `engine-patches/managed-engine.lock.json` and `engine-patches/README.md`.
- Build and verification: `tools/build-managed-engine.ps1`, `tools/prepare-engines.ps1`.

The torrent library replacement remains `github.com/tsynik/torrent v1.2.31`, as specified in the unchanged upstream `server/go.mod`/`go.sum`. The source patch binds blocking torrent reads to the HTTP request context so a client disconnect releases readers waiting for unavailable data. It preserves seek/range behavior and is covered by Go regressions. Executables are compiled from the corresponding source and started as separate processes.

## Playback libraries

`media_kit` and its Flutter integration packages are MIT-licensed: https://github.com/media-kit/media-kit. Packaged native libraries are libmpv/FFmpeg builds supplied by the audio packages. Their upstream component licenses and source/build recipes accompany their source projects; the Flutter wrapper's MIT license does not replace native component licenses.

- Windows audio build: `mpv-dev-x86_64-20230924-git-652a1dd.7z`, provided by `media_kit_libs_windows_audio`; source/build recipes: https://github.com/media-kit/libmpv-win32-audio-build, release: https://github.com/media-kit/libmpv-win32-audio-build/releases/tag/2023-09-24.
- Android audio builds: `v1.1.8`, provided by `media_kit_libs_android_audio`; source/build recipes: https://github.com/media-kit/libmpv-android-audio-build, release: https://github.com/media-kit/libmpv-android-audio-build/releases/tag/v1.1.8.
- libmpv source/licenses: https://github.com/mpv-player/mpv.
- FFmpeg source/licenses: https://ffmpeg.org/legal.html and https://git.ffmpeg.org/ffmpeg.git.

For redistribution, keep this notice, the GPL text, dependency notices and corresponding source/build information alongside the application. The local release includes a Mumpa source archive and matching engine source archive. This project does not include third-party commercial music.

## Other dependencies

Windows includes the unmodified **Jackett v0.24.2806** binaries as a separate managed process. Jackett is GPL-2.0; its LICENSE remains inside the bundled archive and extracted runtime. Matching source: https://github.com/Jackett/Jackett/tree/v0.24.2806; source archive: https://github.com/Jackett/Jackett/archive/refs/tags/v0.24.2806.zip. Binary provenance and pinned SHA-256 are in `tools/prepare-jackett.ps1`. The release includes the matching Jackett source archive alongside Mumpa and TorrServer sources.

`flutter_inappwebview` (Apache-2.0), `html`, `enough_convert` and `archive` retain their upstream licenses; their versioned notices are recorded in Flutter's license registry. Windows native browser uses the installed Microsoft Edge WebView2 runtime.

Flutter (BSD-3-Clause): https://github.com/flutter/flutter. `audio_service`, `audio_session`, `file_picker`, `path_provider`, `path`, `crypto`, `http`, `audio_metadata_reader` and `xml` retain their respective package licenses. Exact versions and transitive packages are recorded by `pubspec.lock`; notices are included in Flutter's `NOTICES` asset.

## Optional Windows challenge helper

Windows bundles unmodified **FlareSolverr v3.5.2**, MIT License, Copyright (c) 2026 Diego Heras and contributors. Its complete license is retained in `assets/flaresolverr/LICENSE.txt`. Matching source revision: `93125d6ea6956906c8dfa29e169b2dc67d993dc3`; source archive is included in `artifacts/sources/FlareSolverr-v3.5.2-source.zip` for redistribution.

- Source: https://github.com/FlareSolverr/FlareSolverr/tree/93125d6ea6956906c8dfa29e169b2dc67d993dc3
- Release: https://github.com/FlareSolverr/FlareSolverr/releases/tag/v3.5.2
- Binary SHA-256: `309abd7c821546325ae6c509b40d969c5e39034be2314d21b3f5e0517feda7a7`.
- Source ZIP SHA-256: `cfd9797fa59f43bba74820d0215945fa233fdd5c07377b66f4390b89c93167f1`.
- Downloads and verification: `tools/prepare-flaresolverr.ps1`.

The separate optional process includes Python, Chromium and upstream Python dependencies. Their package notices remain inside the unmodified archive/runtime. Chromium uses multiple BSD/MIT and other component licenses; its source is https://chromium.googlesource.com/chromium/src. The matching upstream FlareSolverr build recipe pins Windows Chromium snapshot revision **1681099** (`src/build_package.py`). ChromeDriver is obtained from Google's official Chrome for Testing distribution by upstream startup and retained only inside Mumpa's isolated helper profile; source/build information: https://chromium.googlesource.com/chromium/src/+/main/chrome/test/chromedriver/ and https://googlechromelabs.github.io/chrome-for-testing/.

## Development skills

Architecture and responsive-layout guidance was read from the upstream `flutter/skills` repository: https://github.com/flutter/skills. The two skill files are retained in `dev-skills`; they are development documentation, not application runtime dependencies.
