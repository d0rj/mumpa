import 'dart:io';

/// Android's working directory is not writable. Keep emulator evidence in the
/// app's private cache; reports also return independently through the driver.
Directory testArtifacts() => Directory(
  Platform.isAndroid
      ? '${Directory.systemTemp.path}/mumpa-test-evidence'
      : '${Directory.current.path}/test-output',
);
