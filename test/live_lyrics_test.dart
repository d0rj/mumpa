import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/lyrics_repository.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  test(
    'live LRCLIB returns lyrics through the production repository',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-live-lyrics-');
      final repository = LyricsRepository(root);
      try {
        const track = Track(
          id: 'public-lyrics-probe',
          title: 'Yesterday',
          artist: 'The Beatles',
          album: 'Help!',
          source: TrackSource.local,
        );
        final result = await repository.load(track, remote: true);
        expect(result.plain, isNotEmpty);
        expect(result.lines.length, greaterThan(10));
        await Directory('test-output').create();
        await File('test-output/local-features-live-lyrics.json').writeAsString(
          jsonEncode({
            'provider': 'LRCLIB',
            'realHttp': true,
            'synced': result.synced,
            'lineCount': result.lines.length,
            'characters': result.plain.length,
          }),
        );
      } finally {
        repository.close();
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('LRCLIB_LIVE'),
  );
}
