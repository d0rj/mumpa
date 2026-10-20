import 'dart:ffi';
import 'dart:io';

@Native<Uint64 Function()>(
  symbol: 'mpv_client_api_version',
  assetId: 'package:mumpa_audio_runtime/libmpv',
)
external int _clientApiVersion();

/// The native call keeps the bundled code asset reachable in release builds.
String get audioRuntimeLibrary {
  if (_clientApiVersion() == 0) {
    throw StateError('libmpv client API unavailable');
  }
  return Platform.isWindows ? 'mpv_audio_kit.dll' : 'libmpv_audio_kit.so';
}
