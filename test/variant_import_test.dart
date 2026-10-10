import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_metainfo.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';

import 'support.dart';

class _MetadataOnlyTorrentService extends TorrentService {
  _MetadataOnlyTorrentService(http.Client client)
    : super(endpoint: () async => 'http://localhost', client: client);

  @override
  Future<void> waitForAudio(
    Uri uri, {
    SourceOperation? operation,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    operation?.check();
  }
}

Uint8List _bencode(Object value) {
  if (value is int) return Uint8List.fromList(ascii.encode('i${value}e'));
  if (value is String) return _bencode(Uint8List.fromList(utf8.encode(value)));
  if (value is Uint8List) {
    return Uint8List.fromList([...ascii.encode('${value.length}:'), ...value]);
  }
  if (value is List) {
    return Uint8List.fromList([
      108,
      ...value.expand((item) => _bencode(item as Object)),
      101,
    ]);
  }
  final map = value as Map<String, Object>;
  final keys = map.keys.toList()..sort();
  return Uint8List.fromList([
    100,
    ...keys.expand((key) => [..._bencode(key), ..._bencode(map[key]!)]),
    101,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppController app;
  late FakeAudioBackend backend;
  late TorrentInfo metainfo;
  late TrackVariant selectedVariant;
  late Map<String, Object> serverData;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-variant-import-');
    final bytes = _bencode(<String, Object>{
      'info': <String, Object>{
        'name': 'Band - Album',
        'piece length': 16384,
        'pieces': Uint8List(20),
        // The selected file is ordinal 1 in metainfo, but stream ID 2 in
        // the server's authoritative, sorted file_stats response.
        'files': [
          <String, Object>{
            'length': 200,
            'path': ['02 - Selected.wav'],
          },
          <String, Object>{
            'length': 7,
            'path': ['cover.jpg'],
          },
          <String, Object>{
            'length': 100,
            'path': ['01 - First.wav'],
          },
        ],
      },
    });
    metainfo = readTorrentMetainfo(bytes);
    final source = await File(
      '${root.path}/source.torrent',
    ).writeAsBytes(bytes);
    serverData = {
      'hash': metainfo.hash,
      'title': 'Band - Album',
      'file_stats': <Map<String, Object>>[
        {'id': 1, 'path': 'Band - Album/01 - First.wav', 'length': 100},
        {'id': 2, 'path': 'Band - Album/02 - Selected.wav', 'length': 200},
        {'id': 3, 'path': 'Band - Album/cover.jpg', 'length': 7},
      ],
    };
    final torrents = _MetadataOnlyTorrentService(
      MockClient((request) async {
        if (request.url.path == '/torrent/upload') {
          return http.Response(jsonEncode({'hash': serverData['hash']}), 200);
        }
        expect(request.url.path, '/torrents');
        expect((jsonDecode(request.body) as Map)['action'], 'get');
        return http.Response(jsonEncode(serverData), 200);
      }),
    );
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('autoCache', false);
    backend = FakeAudioBackend();
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: backend,
    );
    await playback.initialize(platformAudio: false);
    app = AppController(
      library: library,
      playback: playback,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
    );
    selectedVariant = TrackVariant(
      release: const SearchRelease(
        title: 'Band - Album',
        link: 'https://example.test/album.torrent',
      ),
      track: torrents.tracks(metainfo).first,
      info: metainfo,
      source: source.path,
      edition: '',
    );
  });

  tearDown(() async {
    app.dispose();
    app.downloads.dispose();
    await app.playback.close();
    app.torrents.dispose();
    await app.library.flush();
    app.library.dispose();
    await root.delete(recursive: true);
  });

  test(
    'variant uses sorted server ID while preserving saved queue and favorites',
    () async {
      final authoritative = TorrentInfo.fromJson(serverData);
      final savedTracks = app.torrents.tracks(authoritative);
      final playlist = await app.library.openSourceCollection(
        hash: authoritative.hash,
        name: 'My existing collection',
        tracks: savedTracks,
      );
      final firstId = savedTracks.first.id;
      final selectedId = savedTracks.last.id;
      final originalOrder = List<String>.of(playlist.trackIds);
      await app.library.toggleLike(firstId);
      await app.library.togglePlaylistLike(playlist.id);
      expect(selectedVariant.track.torrentIndex, 1);
      expect(selectedVariant.track.id, firstId);
      expect(selectedVariant.track.torrentPath, savedTracks.last.torrentPath);

      await app.playTrackVariant(selectedVariant);

      expect(app.error, isNull);
      expect(app.playback.current?.id, selectedId);
      expect(app.playback.current?.title, 'Selected');
      expect(app.playback.current?.torrentIndex, 2);
      expect(Uri.parse(backend.opened!).queryParameters['index'], '2');
      expect(app.playback.queue.map((track) => track.id), originalOrder);
      expect(app.playback.contextPlaylistId, playlist.id);
      expect(app.library.tracks.length, 2);
      expect(app.library.liked, {firstId});
      expect(app.library.byId(firstId)?.title, 'First');
      expect(app.library.isPlaylistLiked(playlist.id), isTrue);
      expect(app.playlist?.name, 'My existing collection');
      expect(app.playlist?.trackIds, originalOrder);
    },
  );

  for (final enqueue in [false, true]) {
    test(
      enqueue
          ? 'variant enqueue still works after removal from source playlist'
          : 'variant playback still works after removal from source playlist',
      () async {
        final authoritative = TorrentInfo.fromJson(serverData);
        final savedTracks = app.torrents.tracks(authoritative);
        final playlist = await app.library.openSourceCollection(
          hash: authoritative.hash,
          name: 'My edited collection',
          tracks: savedTracks,
        );
        final first = savedTracks.first;
        final selected = savedTracks.last;
        await app.library.toggleLike(selected.id);
        await app.library.togglePlaylistLike(playlist.id);
        await app.library.removeFromPlaylist(playlist.id, selected.id);
        expect(app.library.playlists.single.trackIds, [first.id]);

        if (enqueue) {
          await app.playback.playTracks([
            first,
          ], contextPlaylistId: playlist.id);
          await app.enqueueTrackVariant(selectedVariant);
        } else {
          await app.playTrackVariant(selectedVariant);
        }

        expect(app.error, isNull);
        expect(app.playback.queue.map((track) => track.id), [
          first.id,
          selected.id,
        ]);
        expect(app.playback.current?.id, enqueue ? first.id : selected.id);
        expect(
          Uri.parse(backend.opened!).queryParameters['index'],
          enqueue ? '1' : '2',
        );
        expect(app.playback.contextPlaylistId, playlist.id);
        expect(app.library.tracks.map((track) => track.id), [
          first.id,
          selected.id,
        ]);
        expect(app.library.liked, {selected.id});
        expect(app.library.isPlaylistLiked(playlist.id), isTrue);
        expect(app.library.playlists.single.name, 'My edited collection');
        expect(app.library.playlists.single.trackIds, [first.id]);
      },
    );
  }

  for (final fault in ['hash', 'length', 'duplicate']) {
    test('variant rejects changed or ambiguous $fault before import', () async {
      final files = serverData['file_stats'] as List<Map<String, Object>>;
      switch (fault) {
        case 'hash':
          serverData['hash'] = 'another-info-hash';
          break;
        case 'length':
          files[1]['length'] = 199;
          break;
        case 'duplicate':
          files.add({...files[1], 'id': 4});
          break;
      }
      await app.playTrackVariant(selectedVariant);
      expect(app.error, contains('Список файлов раздачи изменился'));
      expect(app.library.tracks, isEmpty);
      expect(app.library.playlists, isEmpty);
      expect(backend.opened, isNull);
    });
  }
}
