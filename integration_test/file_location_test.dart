import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mumpa/data/file_location_service.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/domain/models.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native Explorer selects a file with Unicode and spaces', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('FILE_LOCATION_TEST') ||
        !Platform.isWindows) {
      return;
    }
    await tester.runAsync(() async {
      // Keep this harmless fixture for inspecting the selected Explorer item.
      final root = Directory(p.absolute('test-output', 'file-location-native'));
      final library = LibraryRepository(root);
      await library.load();
      final file = await File(
        p.join(library.downloads.path, 'Песня & live, 01.flac'),
      ).create(recursive: true);
      final track = Track(
        id: 'native-location',
        title: 'Location test',
        artist: 'Fixture',
        album: 'Fixture',
        source: TrackSource.torrent,
        cachedPath: file.path,
      );
      try {
        await FileLocationService.revealTrack(library, track);
        await expectLater(
          const MethodChannel(
            'app.mumpa/windows_player',
          ).invokeMethod<void>('revealFile', '${file.path}.missing'),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'file-not-found',
            ),
          ),
        );
        await File('test-output/file-location-native.json').writeAsString(
          jsonEncode({
            'file': file.path,
            'reveal': 'passed',
            'missingFile': 'passed',
          }),
        );
      } finally {
        library.dispose();
      }
    });
  });
}
