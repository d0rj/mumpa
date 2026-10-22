import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/lyrics_repository.dart';
import 'package:mumpa/domain/lyrics.dart';
import 'package:mumpa/domain/models.dart';

void main() {
  test(
    'late lookup preserves a user LRC imported during the request',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-lyrics-race-');
      final started = Completer<void>(), response = Completer<http.Response>();
      final repository = LyricsRepository(
        root,
        client: MockClient((_) {
          started.complete();
          return response.future;
        }),
      );
      const track = Track(
        id: 'race',
        title: 'Song',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.torrent,
      );
      try {
        final loading = repository.load(track, remote: true);
        await started.future;
        await repository.save(track, '[00:02]User', user: true);
        response.complete(
          http.Response(jsonEncode({'plainLyrics': 'Remote'}), 200),
        );
        expect((await loading).lines.single.text, 'User');
        expect((await repository.load(track)).lines.single.text, 'User');
      } finally {
        repository.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'LRC parses repeated timestamps, fractional times, offsets and binary lookup',
    () {
      final lyrics = Lyrics.parse(
        '[ar:Band]\n[offset:-100]\n[00:01.2][00:03.25]Repeated\n[00:02.003]Second\n[00:99]Invalid',
      );
      expect(lyrics.lines.map((l) => l.time.inMilliseconds), [
        1100,
        1903,
        3150,
      ]);
      expect(lyrics.indexAt(const Duration(milliseconds: 1099)), -1);
      expect(lyrics.indexAt(const Duration(milliseconds: 1903)), 1);
      expect(lyrics.lines.last.text, 'Repeated');
    },
  );
  test(
    'local sidecar and user cache work offline; remote is explicit and cached',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-lyrics-');
      var requests = 0;
      final repository = LyricsRepository(
        root,
        client: MockClient((request) async {
          requests++;
          expect(request.url.host, 'lrclib.net');
          expect(request.url.queryParameters['artist_name'], 'Band');
          expect(request.headers['User-Agent'], contains('Mumpa'));
          return http.Response(
            jsonEncode({'syncedLyrics': '[00:01.00]Hello'}),
            200,
          );
        }),
      );
      final track = Track(
        id: 'a',
        title: 'Title',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.local,
        localPath: '${root.path}/a.wav',
      );
      try {
        expect((await repository.load(track)).plain, isEmpty);
        expect(requests, 0);
        expect((await repository.load(track, remote: true)).synced, isTrue);
        expect(requests, 1);
        expect((await repository.load(track)).synced, isTrue);
        expect(requests, 1);
        await File('${root.path}/a.lrc').writeAsString('[00:02]Sidecar');
        expect((await repository.load(track)).lines.single.text, 'Sidecar');
      } finally {
        repository.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'missing lyrics are cached; oversized and unavailable responses are bounded',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-lyrics-error-');
      var requests = 0;
      final repository = LyricsRepository(
        root,
        client: MockClient((_) async {
          requests++;
          return http.Response('', 404);
        }),
      );
      const track = Track(
        id: 'a',
        title: 'Title',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.torrent,
      );
      try {
        await repository.load(track, remote: true);
        await repository.load(track, remote: true);
        expect(requests, 1);
        await expectLater(
          repository.save(track, 'x' * (LyricsRepository.maxBytes + 1)),
          throwsFormatException,
        );
      } finally {
        repository.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'user-selected LRC overrides a sidecar and Retry-After prevents another request',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-lyrics-retry-');
      var requests = 0;
      final repository = LyricsRepository(
        root,
        client: MockClient((_) async {
          requests++;
          return http.Response('', 429, headers: {'retry-after': '1'});
        }),
      );
      final track = Track(
        id: 'retry',
        title: 'Title',
        artist: 'Band',
        album: 'Album',
        source: TrackSource.local,
        localPath: '${root.path}/a.wav',
      );
      try {
        await File('${root.path}/a.lrc').writeAsString('[00:01]Original');
        await repository.save(track, '[00:02]User', user: true);
        expect((await repository.load(track)).lines.single.text, 'User');
        const remote = Track(
          id: 'remote',
          title: 'Other',
          artist: 'Band',
          album: 'Album',
          source: TrackSource.torrent,
        );
        await expectLater(
          repository.load(remote, remote: true),
          throwsA(isA<HttpException>()),
        );
        await expectLater(
          repository.load(remote, remote: true),
          throwsA(isA<HttpException>()),
        );
        expect(requests, 1);
      } finally {
        repository.close();
        await root.delete(recursive: true);
      }
    },
  );
}
