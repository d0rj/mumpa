import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/deezer_artwork_repository.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('mumpa-deezer-'),
  );
  tearDown(() async => root.delete(recursive: true));

  test(
    'absent MusicBrainz covers fall back to scoped artist albums and persist',
    () async {
      var artistQueries = 0, albumQueries = 0, images = 0;
      final cache = DiskMediaCache(root);
      final repo = MusicMetadataRepository(
        cache: cache,
        requestInterval: Duration.zero,
        client: MockClient((request) async {
          final url = request.url;
          if (url.host == 'musicbrainz.org') {
            return http.Response('{"release-groups":[]}', 200);
          }
          if (url.path == '/search/artist') {
            artistQueries++;
            return http.Response(
              '{"data":[{"id":1,"name":"Ежемесячные"},{"id":2,"name":"Месячные"}]}',
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (url.path == '/artist/1/albums') {
            albumQueries++;
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'title': 'Родничок',
                    'cover_medium':
                        'https://cdn-images.dzcdn.net/images/one.jpg',
                  },
                  {
                    'title': 'Barbiesize',
                    'cover_medium':
                        'https://cdn-images.dzcdn.net/images/two.jpg',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          expect(url.host, 'cdn-images.dzcdn.net');
          images++;
          return http.Response.bytes(
            [255, 216, 255, 217],
            200,
            headers: {'content-type': 'image/jpeg'},
          );
        }),
      );
      try {
        final paths = await Future.wait([
          repo.coverForAlbum('Ежемесячные', 'Родничок'),
          repo.coverForAlbum('Ежемесячные', 'BARBIESIZE (feat. GSPD)'),
        ]);
        expect(paths.every((path) => path != null), isTrue);
        expect(artistQueries, 1);
        expect(albumQueries, 1);
        expect(images, 2);
        final restarted = MusicMetadataRepository(
          cache: DiskMediaCache(root),
          client: MockClient(
            (_) async => throw StateError('No network after restart'),
          ),
        );
        try {
          expect(
            await restarted.coverForAlbum('Ежемесячные', 'Родничок'),
            paths.first,
          );
        } finally {
          restarted.dispose();
        }
        await cache.clear();
        expect(await repo.coverForAlbum('Ежемесячные', 'Родничок'), isNotNull);
        expect(images, 3);
      } finally {
        repo.dispose();
      }
    },
  );

  test(
    'fallback also runs on unavailable MB and rejects unrelated artist or CDN',
    () async {
      var images = 0;
      final repo = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        requestInterval: Duration.zero,
        client: MockClient((request) async {
          if (request.url.host == 'musicbrainz.org') {
            return http.Response('down', 503);
          }
          if (request.url.path == '/search/artist') {
            return http.Response(
              '{"data":[{"id":1,"name":"Band"},{"id":2,"name":"Other"}]}',
              200,
            );
          }
          if (request.url.path == '/artist/1/albums') {
            return http.Response(
              '{"data":[{"title":"Album","cover_medium":"https://evil.example/cover"}]}',
              200,
            );
          }
          images++;
          return http.Response('unexpected', 500);
        }),
      );
      try {
        expect(await repo.coverForAlbum('Band', 'Album'), isNull);
        expect(await repo.coverForAlbum('Unrelated', 'Album'), isNull);
        expect(images, 0);
      } finally {
        repo.dispose();
      }
    },
  );

  test('clearing during fallback fetch prevents stale image writes', () async {
    final started = Completer<void>(), image = Completer<http.Response>();
    final cache = DiskMediaCache(root);
    final client = MockClient((request) async {
      if (request.url.path == '/search/artist') {
        return http.Response('{"data":[{"id":1,"name":"Band"}]}', 200);
      }
      if (request.url.path == '/artist/1/albums') {
        return http.Response(
          '{"data":[{"title":"Album","cover_medium":"https://cdn-images.dzcdn.net/a.jpg"}]}',
          200,
        );
      }
      started.complete();
      return image.future;
    });
    final repo = DeezerArtworkRepository(cache: cache, client: client);
    final pending = repo.cover('Band', 'Album', cache.generation);
    final rejected = expectLater(pending, throwsA(isA<Exception>()));
    await started.future;
    await cache.clear();
    image.complete(
      http.Response.bytes(
        [255, 216, 255, 217],
        200,
        headers: {'content-type': 'image/jpeg'},
      ),
    );
    await rejected;
    expect((await cache.stats()).count, 0);
    repo.dispose();
    client.close();
  });

  test('broken edition image does not hide another valid cover', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/search/artist') {
        return http.Response('{"data":[{"id":1,"name":"Band"}]}', 200);
      }
      if (request.url.path == '/artist/1/albums') {
        return http.Response(
          '{"data":[{"title":"Album","cover_medium":"https://cdn-images.dzcdn.net/missing.jpg"},{"title":"Album","cover_medium":"https://cdn-images.dzcdn.net/valid.jpg"}]}',
          200,
        );
      }
      if (request.url.path.endsWith('missing.jpg')) {
        return http.Response('missing', 404);
      }
      return http.Response.bytes(
        [255, 216, 255, 217],
        200,
        headers: {'content-type': 'image/jpeg'},
      );
    });
    final cache = DiskMediaCache(root);
    final repo = DeezerArtworkRepository(cache: cache, client: client);
    try {
      expect(await repo.cover('Band', 'Album', cache.generation), isNotNull);
    } finally {
      repo.dispose();
      client.close();
    }
  });

  test(
    'only catalogue type and explicit featuring wrappers are normalized',
    () {
      expect(
        artworkAlbumIdentity('Barbiesize (feat. GSPD) (EP)'),
        artworkAlbumIdentity('Barbiesize - EP'),
      );
      expect(artworkAlbumIdentity('Ёжики'), artworkAlbumIdentity('Ежики'));
      expect(
        artworkAlbumIdentity('Album (Live)'),
        isNot(artworkAlbumIdentity('Album')),
      );
      expect(
        artworkAlbumIdentity('Album (Deluxe)'),
        isNot(artworkAlbumIdentity('Album')),
      );
    },
  );
}
