# Component notices and source locations

Mumpa application code is GPL-3.0; see `LICENSE`. Original generated demo audio, procedural artwork and branding are part of this project. Manrope is SIL Open Font License 1.1; its notice is in `assets/fonts/OFL.txt`. Dependency versions are in `pubspec.lock`, and Flutter's generated license registry is accessible in Settings → Licenses.

## Torrent engine

The unmodified packaged executables are TorrServer **MatriX.145.2**, GPL-3.0. Copyright belongs to the TorrServer contributors. Matching source revision: **bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9**.

- Source: https://github.com/YouROK/TorrServer/tree/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9
- Source archive: https://github.com/YouROK/TorrServer/archive/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9.zip
- Release/binary provenance: https://github.com/YouROK/TorrServer/releases/tag/MatriX.145.2
- Copyright/license: https://github.com/YouROK/TorrServer/blob/bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9/LICENSE
- Pinned executable SHA-256 and downloads: `tools/prepare-engines.ps1`.

The torrent library replacement is `github.com/tsynik/torrent v1.2.31`, as specified in the matching engine `server/go.mod`. The executable is started as a separate process; no binary patches are applied.

## Playback libraries

`media_kit` and its Flutter integration packages are MIT-licensed: https://github.com/media-kit/media-kit. Packaged native libraries are libmpv/FFmpeg builds supplied by the audio packages. Their upstream component licenses and source/build recipes accompany their source projects; the Flutter wrapper's MIT license does not replace native component licenses.

- Windows audio build: `mpv-dev-x86_64-20230924-git-652a1dd.7z`, provided by `media_kit_libs_windows_audio`; source/build recipes: https://github.com/media-kit/libmpv-win32-audio-build, release: https://github.com/media-kit/libmpv-win32-audio-build/releases/tag/2023-09-24.
- Android audio builds: `v1.1.8`, provided by `media_kit_libs_android_audio`; source/build recipes: https://github.com/media-kit/libmpv-android-audio-build, release: https://github.com/media-kit/libmpv-android-audio-build/releases/tag/v1.1.8.
- libmpv source/licenses: https://github.com/mpv-player/mpv.
- FFmpeg source/licenses: https://ffmpeg.org/legal.html and https://git.ffmpeg.org/ffmpeg.git.

For redistribution, keep this notice, the GPL text, dependency notices and corresponding source/build information alongside the application. The local release includes a Mumpa source archive and matching engine source archive. This project does not include third-party commercial music.

## Other dependencies

Flutter (BSD-3-Clause): https://github.com/flutter/flutter. `audio_service`, `audio_session`, `file_picker`, `path_provider`, `path`, `crypto`, `http`, `audio_metadata_reader` and `xml` retain their respective package licenses. Exact versions and transitive packages are recorded by `pubspec.lock`; notices are included in Flutter's `NOTICES` asset.

## Development skills

Architecture and responsive-layout guidance was read from the upstream `flutter/skills` repository: https://github.com/flutter/skills. The two skill files are retained in `dev-skills`; they are development documentation, not application runtime dependencies.
