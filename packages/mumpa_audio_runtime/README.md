# Mumpa DSP runtime

This small native-assets package bundles the pinned `libmpv-r17` audio runtime
from [mpv_audio_kit](https://github.com/ales-drnz/mpv_audio_kit/releases/tag/libmpv-r17),
mpv 0.41.0 / FFmpeg 8.1.1. SHA-256 pins match that release's `manifest.json`
and mpv_audio_kit 0.5.1's published build hook. Binaries are downloaded only
during builds, verified, and copied into the application by Flutter native assets.
The running app never downloads an audio runtime.

Windows x64/arm64, Android armv7/arm64/x86_64 and Linux x64/arm64 have explicit
pins. Windows x64 and Android APK builds are validated in this workspace;
Linux entries support the existing CI unit-test host. Other platforms fail
clearly instead of choosing an incompatible library.

`lib/logic/audio_runtime.dart` initializes media_kit with the bundled library.
The reachable `@Native` client API call keeps the code asset in release builds.
Android loads this exact library through `System.loadLibrary` before Dart so
JNI_OnLoad registers its JavaVM for AudioTrack. The existing media_kit audio
package remains for its Android content/file helpers and original notices.

DSP uses named filter parameters. The runtime deliberately does not include
the lavfi `volume` filter: EQ headroom uses a pan preamp and preserves
the separate user volume setting. `loudnorm` is one-pass live normalization,
not a full-track analysis pass or alteration of downloaded files.

Upstream build recipes and patches: https://github.com/ales-drnz/libmpv-scripts.
Retain the component notices and corresponding sources when distributing;
see `../../THIRD_PARTY_NOTICES.md`.
