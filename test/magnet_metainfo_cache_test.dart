import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/magnet_metainfo_cache.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_metainfo.dart';

Uint8List _torrent(String filename) {
  final info =
      'd6:lengthi123e4:name${utf8.encode(filename).length}:$filename'
      '12:piece lengthi16384e6:pieces20:00000000000000000000e';
  return Uint8List.fromList(utf8.encode('d4:info${info}e'));
}

void main() {
  late Directory root;
  final bytes = _torrent('Ежемесячные.mp3');
  final hash = readTorrentMetainfo(bytes).hash;
  final magnet = Uri.parse(
    'magnet:?xt=urn:btih:$hash&dn=private-title&tr=https://private.example/announce?passkey=secret',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-metainfo-cache-');
  });
  tearDown(() async => root.delete(recursive: true));

  MockClient cacheClient({
    Uint8List? body,
    List<http.Request>? requests,
    String? redirect,
  }) => MockClient((request) async {
    requests?.add(request);
    expect(request.method, 'GET');
    expect(request.url.host, anyOf('torrage.info', 't2.torrage.info'));
    expect(request.url.toString(), isNot(contains('private')));
    expect(request.url.queryParameters['h'], hash.toUpperCase());
    if (request.url.host == 't2.torrage.info') {
      return http.Response.bytes(body ?? bytes, 200);
    }
    if (request.url.path == '/download.php') {
      // Only the normal public download link is interpreted; no JS is run.
      expect(request.url.queryParameters['ttl'], '654321_TSRqpo');
      expect(
        request.headers['referer'],
        '${MagnetMetainfoCache.origin}/torrent.php?h=${hash.toUpperCase()}',
      );
      return redirect == null
          ? http.Response.bytes(body ?? bytes, 200)
          : http.Response('', 302, headers: {'location': redirect});
    }
    if (request.url.queryParameters.containsKey('ttl')) {
      return http.Response('getTTL("abcDEF_123456"\n);', 200);
    }
    return http.Response(
      '<script src="https://ads.example/run.js"></script>'
      '<script src="/torrent.php?h=${hash.toUpperCase()}&amp;ttl=123"></script>',
      200,
    );
  });

  test(
    'checks exact hash and music, reuses cache without disclosing source',
    () async {
      final requests = <http.Request>[];
      final client = cacheClient(requests: requests);
      try {
        final file = await MagnetMetainfoCache.resolve(client, magnet, root);
        expect(file, isNotNull);
        final saved = await file!.readAsBytes();
        expect(readTorrentMetainfo(saved).hash, hash);
        expect(
          utf8.decode(saved),
          contains('https://private.example/announce?passkey=secret'),
        );
        expect(requests.length, 3);
        expect(
          (await MagnetMetainfoCache.resolve(client, magnet, root))!.path,
          file.path,
        );
        expect(requests.length, 3);
        expect(await root.list().length, 1);
      } finally {
        client.close();
      }
    },
  );

  test('wrong hash and nonmusic never enter the cache', () async {
    for (final body in [_torrent('other.mp3'), _torrent('setup.exe')]) {
      final client = cacheClient(body: body);
      try {
        expect(await MagnetMetainfoCache.resolve(client, magnet, root), isNull);
        expect(await root.list().isEmpty, isTrue);
      } finally {
        client.close();
      }
    }
    final nonmusic = _torrent('setup.exe');
    final client = MockClient((_) async => http.Response('unavailable', 404));
    try {
      final otherHash = readTorrentMetainfo(nonmusic).hash;
      await File(
        '${root.path}/metainfo-$otherHash.torrent',
      ).writeAsBytes(nonmusic);
      expect(
        await MagnetMetainfoCache.resolve(
          client,
          Uri.parse('magnet:?xt=urn:btih:$otherHash'),
          root,
        ),
        isNull,
      );
    } finally {
      client.close();
    }
  });

  test(
    'follows only bounded HTTPS download redirects within the cache service',
    () async {
      for (final target in [
        'https://t2.torrage.info/download?h=${hash.toUpperCase()}',
        'https://other.example/download?h=${hash.toUpperCase()}',
        'http://t2.torrage.info/download?h=${hash.toUpperCase()}',
      ]) {
        final requests = <http.Request>[];
        final client = cacheClient(redirect: target, requests: requests);
        try {
          final result = await MagnetMetainfoCache.resolve(
            client,
            magnet,
            root,
          );
          if (target.startsWith('https://t2.')) {
            expect(result, isNotNull);
            expect(requests.length, 4);
            expect(
              requests.last.headers['referer'],
              requests[2].headers['referer'],
            );
            await result!.delete();
          } else {
            expect(result, isNull);
            expect(requests.length, 3);
            expect(await root.list().isEmpty, isTrue);
          }
        } finally {
          client.close();
        }
      }
    },
  );

  test(
    'cache failures preserve magnet fallback and cancellation propagates',
    () async {
      final client = MockClient((_) async => http.Response('no cache', 404));
      try {
        expect(await MagnetMetainfoCache.resolve(client, magnet, root), isNull);
        final cancelled = SourceOperation()..cancel();
        await expectLater(
          MagnetMetainfoCache.resolve(
            client,
            magnet,
            root,
            operation: cancelled,
          ),
          throwsA(isA<SourceCancelled>()),
        );
      } finally {
        client.close();
      }
    },
  );

  test('does not follow a control script on another host', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(
        '<script src="https://other.example/torrent.php?h=$hash&ttl=1"></script>',
        200,
      );
    });
    try {
      expect(await MagnetMetainfoCache.resolve(client, magnet, root), isNull);
      expect(calls, 1);
    } finally {
      client.close();
    }
  });

  test(
    'retains original announce and magnet parameters without rewriting info',
    () {
      const old = 'http://old.example/ann';
      const fresh = 'http://new.example/ann?magnet';
      final source = Uint8List.fromList([
        ...ascii.encode('d8:announce${old.length}:$old'),
        ...bytes.sublist(1),
      ]);
      final uri = Uri(
        scheme: 'magnet',
        queryParameters: {'xt': 'urn:btih:$hash', 'tr': fresh},
      );
      final result = addMagnetTrackers(source, uri);
      expect(readTorrentMetainfo(result).hash, hash);
      expect(utf8.decode(result), contains(old));
      expect(utf8.decode(result), contains(fresh));
      expect(addMagnetTrackers(result, uri), result);
      expect(
        addMagnetTrackers(source, Uri.parse('magnet:?tr=javascript:bad')),
        source,
      );
    },
  );

  test('an unresponsive cache has a bounded wait', () async {
    final pending = Completer<http.Response>();
    final client = MockClient((_) => pending.future);
    try {
      expect(
        await MagnetMetainfoCache.resolve(
          client,
          magnet,
          root,
          timeout: const Duration(milliseconds: 20),
        ),
        isNull,
      );
      pending.complete(http.Response('too late', 404));
      await Future<void>.delayed(Duration.zero);
      expect(await root.list().isEmpty, isTrue);
    } finally {
      client.close();
    }
  });
}
