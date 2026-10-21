import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';

void main() {
  test(
    'real MusicBrainz profile for Ежемесячные',
    () async {
      final root = await Directory('test-output').createTemp('metadata-live-');
      final repo = MusicMetadataRepository(cache: DiskMediaCache(root));
      try {
        final artist = await repo.artist('Ежемесячные');
        expect(artist, isNotNull);
        expect(artist!.id, 'f646239d-504c-479d-a047-8ab4ee22c9f3');
        expect(artist.albums, isNotEmpty);
        expect(artist.recordings, isNotEmpty);
        await File('test-output/music-metadata-live.json').writeAsString(
          jsonEncode({
            'artist': artist.name,
            'id': artist.id,
            'albums': artist.albums.length,
            'recordings': artist.recordings.length,
            'checkedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        );
      } finally {
        repo.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('MUSIC_METADATA_LIVE_TEST'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
