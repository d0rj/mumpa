import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/catalog_repository.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/mcp/mcp_server.dart';
import 'package:mumpa/mcp/mumpa_mcp.dart';

import 'support.dart';

class _Catalog extends CatalogRepository {
  _Catalog(Directory root)
    : super(musicBrainz: MusicMetadataRepository(cache: DiskMediaCache(root)));

  @override
  Future<CatalogSearchResult> search(
    String query, {
    SourceOperation? operation,
  }) {
    if (query == 'wait') {
      return operation!.wait(Completer<CatalogSearchResult>().future);
    }
    return Future.value(
      const CatalogSearchResult(
        [
          MusicRecording(id: '01', title: 'First', artist: 'Mumpa Sessions'),
          MusicRecording(id: '02', title: 'Second', artist: 'Mumpa Sessions'),
        ],
        ['Deezer'],
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
    musicBrainz.dispose();
  }
}

class _Client {
  final connection = HttpClient();
  final Uri url;
  final String token;
  int _sequence = 0;
  _Client(this.url, this.token);

  Future<({int status, Json? body})> send(
    Json message, {
    String? auth,
    String? origin,
    String? host,
    String? version,
    String verb = 'POST',
    String? rawBody,
    bool authenticated = true,
  }) async {
    final request = await connection.openUrl(verb, url);
    request.headers.contentType = ContentType.json;
    request.headers.set('Accept', 'application/json, text/event-stream');
    if (authenticated) {
      request.headers.set('Authorization', 'Bearer ${auth ?? token}');
    }
    if (origin != null) request.headers.set('Origin', origin);
    if (host != null) request.headers.set('Host', host);
    if (version != null) request.headers.set('MCP-Protocol-Version', version);
    if (verb == 'POST') {
      final bytes = utf8.encode(rawBody ?? jsonEncode(message));
      if (bytes.length <= 65536) request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close();
    final content = await utf8.decoder.bind(response).join();
    return (
      status: response.statusCode,
      body: content.isEmpty ? null : jsonDecode(content) as Json,
    );
  }

  Future<Json> rpc(String method, [Json params = const {}]) async {
    final id = ++_sequence;
    final reply = await send({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    expect(reply.status, 200);
    expect(reply.body?['id'], id);
    return reply.body!;
  }

  Future<Json> tool(String name, [Json args = const {}, String? error]) async {
    final reply = await rpc('tools/call', {
      'name': 'mumpa_$name',
      'arguments': args,
    });
    final result = reply['result'] as Json;
    expect(result['isError'], error != null);
    final value = result['structuredContent'] as Json;
    expect(jsonDecode(result['content'][0]['text'] as String), value);
    if (error != null) expect(value['error']['code'], error);
    return value;
  }
}

void main() {
  late Directory root;
  late AppController app;
  late MumpaMcp mcp;
  late _Client client;
  late FakeAudioBackend audio;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-mcp-');
    final library = LibraryRepository(root);
    await library.load();
    final file = await File('${root.path}/sample.wav').writeAsBytes([0]);
    await library.upsert([
      for (final (id, title) in [('a', 'Ёлки'), ('b', 'Ночь')])
        Track(
          id: id,
          title: title,
          artist: 'Mumpa Sessions',
          album: 'Demo',
          source: TrackSource.local,
          localPath: file.path,
        ),
    ]);
    final torrents = TorrentService(
      endpoint: () async => throw StateError('Unexpected network'),
    );
    audio = FakeAudioBackend();
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
    );
    await playback.initialize(platformAudio: false);
    app = AppController(
      library: library,
      playback: playback,
      torrents: torrents,
      downloads: DownloadRepository(library, torrents),
      engine: TorrentEngine(root),
      musicCatalog: _Catalog(root),
    );
    mcp = MumpaMcp(app, listenPort: 0);
    expect(mcp.url, isNull);
    await mcp.setEnabled(true);
    client = _Client(mcp.url!, mcp.accessKey!);
  });

  tearDown(() async {
    client.connection.close(force: true);
    await mcp.close();
    await app.shutdown();
    app.library.dispose();
    await root.delete(recursive: true);
  });

  test(
    'MCP negotiation, validation, access control and key revocation',
    () async {
      final init = await client.rpc('initialize', {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'test', 'version': '1.0.0'},
      });
      expect(init['result']['protocolVersion'], '2025-06-18');
      final notification = await client.send({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      expect((notification.status, notification.body), (202, null));
      final tools = (await client.rpc('tools/list'))['result']['tools'] as List;
      expect(
        tools.map((tool) => tool['name']),
        containsAll(['mumpa_library', 'mumpa_play', 'mumpa_operation']),
      );
      expect((await client.send({}, authenticated: false)).status, 401);
      expect((await client.send({}, auth: 'wrong')).status, 401);
      expect(
        (await client.send({}, origin: 'https://example.test')).status,
        403,
      );
      expect((await client.send({}, host: 'rebound.example.test')).status, 403);
      expect((await client.send({}, version: 'old')).status, 400);
      expect((await client.send({}, verb: 'GET')).status, 405);
      expect(
        (await client.send({}, rawBody: '{')).body?['error']['code'],
        -32700,
      );
      await client.tool('player_options', {'volume': 2}, 'invalid_argument');
      expect(
        (await client.rpc('tools/call', {'name': 'unknown'}))['error']['code'],
        -32602,
      );
      final oversized = _Client(client.url, client.token);
      try {
        expect(
          (await oversized.send({}, rawBody: '"${'x' * 65536}"')).status,
          413,
        );
      } finally {
        oversized.connection.close(force: true);
      }

      final oldKey = client.token;
      await mcp.setEnabled(false);
      expect(mcp.url, isNull);
      await mcp.setEnabled(true);
      expect(mcp.accessKey, isNot(oldKey));
      final oldClient = _Client(mcp.url!, oldKey);
      try {
        expect((await oldClient.send({})).status, 401);
      } finally {
        oldClient.connection.close(force: true);
      }
    },
  );

  test(
    'find, play, edit a duplicate queue occurrence and persist a playlist',
    () async {
      final search = await client.tool('library', {
        'kind': 'tracks',
        'query': 'елки',
      });
      expect((search['items'] as List).single['id'], 'a');
      expect(jsonEncode(search), isNot(contains(root.path)));
      await client.tool('play', {
        'track_ids': ['a', 'b'],
      });
      for (var i = 0; i < 50 && !audio.playing; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(audio.playing, isTrue);
      await client.tool('queue_add', {
        'track_ids': ['a', 'b'],
        'placement': 'next',
      });
      final queue = await client.tool('queue', {'limit': 2});
      expect(queue['next_offset'], 2);
      final entries = queue['items'] as List;
      expect(entries.map((entry) => entry['track']['id']), ['a', 'a']);
      expect(entries[0]['entry_id'], isNot(entries[1]['entry_id']));
      final move = {
        'action': 'move',
        'revision': queue['revision'],
        'entry_id': entries[1]['entry_id'],
        'to_index': 3,
      };
      await client.tool('queue_edit', move);
      await client.tool('queue_edit', move, 'stale_queue');
      expect(app.playback.queue.map((track) => track.id), ['a', 'b', 'b', 'a']);
      expect(app.playback.index, 0);
      await client.tool('transport', {'action': 'seek', 'position_ms': 1250});
      expect((await client.tool('state'))['position_ms'], 1250);
      await client.tool('transport', {'action': 'pause'});
      expect(audio.playing, isFalse);
      await client.tool('favorite', {
        'kind': 'track',
        'id': 'a',
        'liked': true,
      });
      await client.tool('favorite', {
        'kind': 'track',
        'id': 'a',
        'liked': true,
      });
      expect(app.library.favoriteTracks.map((track) => track.id), ['a']);
      final playlist = await client.tool('playlist_create', {
        'name': 'For later',
        'track_ids': ['b', 'a'],
      });
      await client.tool('playlist_edit', {
        'action': 'replace',
        'playlist_id': playlist['id'],
        'track_ids': ['a', 'b'],
      });
      final saved = LibraryRepository(root);
      try {
        await saved.load();
        expect(saved.playlistById(playlist['id'] as String)?.trackIds, [
          'a',
          'b',
        ]);
      } finally {
        saved.dispose();
      }
    },
  );

  test(
    'online results can be paginated and active work can be cancelled',
    () async {
      final job = await client.tool('search_online', {
        'kind': 'recordings',
        'query': 'mumpa',
      });
      final args = {'operation_id': job['operation_id'], 'limit': 1};
      final finished = await client.tool('operation', args);
      expect(finished['state'], 'succeeded');
      expect(finished['result']['unavailable_providers'], ['Deezer']);
      expect(finished['result']['next_offset'], 1);
      final last = await client.tool('operation', {...args, 'offset': 1});
      expect(last['result']['items'][0]['title'], 'Second');
      final running = await client.tool('search_online', {
        'kind': 'recordings',
        'query': 'wait',
      });
      expect(running['state'], 'running');
      final pending = {'operation_id': running['operation_id']};
      await client.tool('operation', {...pending, 'cancel': true});
      expect((await client.tool('operation', pending))['state'], 'cancelled');
      expect(app.query, isEmpty);
    },
  );
}
