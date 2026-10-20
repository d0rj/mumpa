import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:mumpa_audio_runtime/mumpa_audio_runtime.dart';

void initializeAudioRuntime() {
  MediaKit.ensureInitialized(
    libmpv: (Platform.isWindows || Platform.isAndroid || Platform.isLinux)
        ? audioRuntimeLibrary
        : null,
  );
}
