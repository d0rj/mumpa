import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/source_operation.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-artist-spelling-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'single-word artist hints use the shared metadata cache across restart',
    () async {
      var requests = 0;
      final repository = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        requestInterval: Duration.zero,
        client: MockClient((request) async {
          requests++;
          expect(request.url.host, 'musicbrainz.org');
          expect(request.url.queryParameters['query'], 'artist:ежемесечные~1');
          expect(request.url.queryParameters['limit'], '8');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'artists': [
                  {'name': 'Ежемесячные'},
                  {'name': 'Ежемесячные'},
                ],
              }),
            ),
            200,
          );
        }),
      );
      expect(await repository.suggestArtistNames('Ежемесечные'), [
        'Ежемесячные',
      ]);
      repository.dispose();
      final offline = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        client: MockClient((_) => throw StateError('must use saved metadata')),
      );
      expect(await offline.suggestArtistNames('Ежемесечные'), ['Ежемесячные']);
      expect(requests, 1);
      offline.dispose();
    },
  );

  test(
    'short, complex and cancelled queries never issue public requests',
    () async {
      var requests = 0;
      final repository = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      for (final query in ['Еже', 'Daft Pnuk', 'artist:(private URL)', '']) {
        expect(await repository.suggestArtistNames(query), isEmpty);
      }
      final operation = SourceOperation()..cancel();
      await expectLater(
        repository.suggestArtistNames('Ежемесечные', operation: operation),
        throwsA(isA<SourceCancelled>()),
      );
      expect(requests, 0);
      repository.dispose();
    },
  );
}
