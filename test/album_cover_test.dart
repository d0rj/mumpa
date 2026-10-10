import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';

void main() {
  test(
    'separate album identity preserves meaningful suffixes and survives offline restart',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-album-cover-');
      const liveId = '48117b90-a16e-34ca-a514-19c702df1158';
      var metadataRequests = 0, coverRequests = 0;
      final repo = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        requestInterval: Duration.zero,
        client: MockClient((request) async {
          if (request.url.host == 'musicbrainz.org') {
            metadataRequests++;
            return http.Response(
              jsonEncode({
                'release-groups': [
                  for (final (title, id) in [
                    ('Album', 'wrong-id'),
                    ('Album (Live)', liveId),
                  ])
                    {
                      'id': id,
                      'title': title,
                      'artist-credit': [
                        {'name': 'Band'},
                      ],
                    },
                ],
              }),
              200,
            );
          }
          coverRequests++;
          expect(request.url.path, contains(liveId));
          return http.Response.bytes(
            [255, 216, 255, 217],
            200,
            headers: {'content-type': 'image/jpeg'},
          );
        }),
      );
      try {
        final results = await Future.wait([
          repo.coverForAlbum('Band', 'Album (Live)'),
          repo.coverForAlbum('Band', 'Album (Live)'),
        ]);
        expect(results.first, isNotNull);
        expect(results.last, results.first);
        expect(metadataRequests, 1);
        expect(coverRequests, 1);
        final restarted = MusicMetadataRepository(
          cache: DiskMediaCache(root),
          requestInterval: Duration.zero,
          client: MockClient((_) async => throw StateError('offline')),
        );
        try {
          expect(
            await restarted.coverForAlbum('Band', 'Album (Live)'),
            results.first,
          );
        } finally {
          restarted.dispose();
        }
      } finally {
        repo.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test('same album title by another artist does not provide a cover', () async {
    final root = await Directory.systemTemp.createTemp(
      'mumpa-ambiguous-cover-',
    );
    var images = 0;
    final repo = MusicMetadataRepository(
      cache: DiskMediaCache(root),
      requestInterval: Duration.zero,
      client: MockClient((request) async {
        if (request.url.host != 'musicbrainz.org') {
          images++;
          return http.Response('missing', 404);
        }
        return http.Response(
          '{"release-groups":[{"id":"48117b90-a16e-34ca-a514-19c702df1158","title":"Album","artist-credit":[{"name":"Another artist"}]}]}',
          200,
        );
      }),
    );
    try {
      expect(await repo.coverForAlbum('Band', 'Album'), isNull);
      expect(images, 0);
    } finally {
      repo.dispose();
      await root.delete(recursive: true);
    }
  });
}
