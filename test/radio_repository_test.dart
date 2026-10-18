import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/radio_repository.dart';
import 'package:mumpa/data/rutracker_service.dart';
import 'package:mumpa/data/similar_artists_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_metainfo.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/domain/similar_artist.dart';

class _Metadata extends MusicMetadataRepository {
  _Metadata(DiskMediaCache cache)
    : super(
        cache: cache,
        client: MockClient((_) async => throw StateError('Unexpected HTTP')),
      );
  int calls = 0;
  bool missing = false;
  @override
  Future<MusicArtist?> artist(String name, {SourceOperation? operation}) async {
    calls++;
    return missing
        ? null
        : MusicArtist(id: 'f646239d-504c-479d-a047-8ab4ee22c9f3', name: name);
  }
}

class _Similar extends SimilarArtistsRepository {
  _Similar(_Metadata metadata)
    : super(cache: metadata.cache, client: metadata.client);
  @override
  Future<List<SimilarArtist>> similarArtists(
    String artistId, {
    SourceOperation? operation,
  }) async => const [
    SimilarArtist(
      id: '37920299-9dc8-4038-954a-ad4cb824e812',
      name: 'Related',
      score: 10,
    ),
  ];
}

class _Indexer extends IndexerService {
  int searches = 0, resolves = 0;
  final queries = <String>[];
  final links = <String>[];
  bool invalid = true;
  @override
  Future<List<SearchRelease>> search(
    String endpoint,
    String key,
    String query, {
    SourceOperation? operation,
  }) async {
    searches++;
    queries.add(query);
    if (query != 'Related') return [];
    return const [
      SearchRelease(
        title: 'Unrelated — Album',
        link: 'https://index/other',
        seeders: 999,
      ),
      SearchRelease(
        title: 'Related — Broken',
        link: 'https://index/broken',
        seeders: 20,
      ),
      SearchRelease(
        title: 'Related — Album',
        link: 'https://index/good',
        seeders: 10,
      ),
      SearchRelease(
        title: 'Related — Extra',
        link: 'https://index/extra',
        seeders: 1,
      ),
    ];
  }

  @override
  Future<({String source, bool file})> resolve(
    String link,
    Directory directory, {
    SourceOperation? operation,
    bool preferCachedMetainfo = false,
  }) async {
    resolves++;
    links.add(link);
    final file = File('${directory.path}/source.torrent');
    final bytes = link.endsWith('/broken') && invalid
        ? utf8.encode('invalid')
        : _encode(<String, Object>{
            'info': <String, Object>{
              'name': 'Related - Album',
              'pieces': Uint8List(20),
              'piece length': 16384,
              'files': [
                <String, Object>{
                  'length': 64,
                  'path': ['01 - First.mp3'],
                },
                <String, Object>{
                  'length': 64,
                  'path': ['02 - Second.mp3'],
                },
              ],
            },
          });
    await file.writeAsBytes(bytes);
    return (source: file.path, file: true);
  }
}

class _Torrents extends TorrentService {
  _Torrents() : super(endpoint: () async => 'http://localhost:1');
  int uploads = 0, probes = 0, resolutions = 0;
  bool dead = false;
  Duration? probeTimeout;
  final resolvedIndexes = <int>[];
  final addedLinks = <String>[];
  @override
  Future<TorrentInfo> add(
    String link, {
    String? title,
    SourceOperation? operation,
    void Function(String)? onProgress,
  }) async {
    addedLinks.add(link);
    return const TorrentInfo(
      hash: 'direct',
      title: 'Related - Album',
      files: [
        TorrentFile(
          index: 177,
          path: 'Related - Album/01 - Direct.mp3',
          bytes: 64,
        ),
      ],
    );
  }

  @override
  Future<TorrentInfo> upload(
    String path, {
    SourceOperation? operation,
    void Function(String)? onProgress,
  }) async {
    uploads++;
    final info = readTorrentMetainfo(await File(path).readAsBytes());
    return TorrentInfo(
      hash: info.hash,
      title: info.title,
      files: [
        for (final f in info.files)
          TorrentFile(index: f.index + 100, path: f.path, bytes: f.bytes),
      ],
    );
  }

  @override
  Future<Uri> resolve(Track track, {SourceOperation? operation}) async {
    resolutions++;
    resolvedIndexes.add(track.torrentIndex!);
    return Uri.parse('http://localhost:1/stream/${track.torrentIndex}');
  }

  @override
  Future<void> waitForAudio(
    Uri uri, {
    SourceOperation? operation,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    probes++;
    probeTimeout = timeout;
    operation?.check();
    if (dead) throw TimeoutException('No payload');
  }
}

class _DirectCatalog extends RuTrackerService {
  @override
  Future<CatalogListing> search(String query, {int offset = 0}) async =>
      CatalogListing(
        releases: query == 'Related'
            ? const [
                SearchRelease(
                  title: 'Related — Album',
                  link: 'https://tracker/viewtopic.php?t=1',
                ),
              ]
            : const [],
      );
  @override
  Future<String> magnet(SearchRelease release) async =>
      'magnet:?xt=urn:btih:direct';
}

Uint8List _encode(Object value) {
  if (value is int) return Uint8List.fromList(ascii.encode('i${value}e'));
  if (value is String) return _encode(Uint8List.fromList(utf8.encode(value)));
  if (value is Uint8List) {
    return Uint8List.fromList([...ascii.encode('${value.length}:'), ...value]);
  }
  if (value is List) {
    return Uint8List.fromList([
      108,
      ...value.expand((v) => _encode(v as Object)),
      101,
    ]);
  }
  final map = value as Map<String, Object>;
  final keys = map.keys.toList()..sort();
  return Uint8List.fromList([
    100,
    ...keys.expand((k) => [..._encode(k), ..._encode(map[k]!)]),
    101,
  ]);
}

void main() {
  late Directory root;
  late LibraryRepository library;
  late _Metadata metadata;
  late _Similar similar;
  late _Indexer indexer;
  late _Torrents torrents;
  late RuTrackerService catalog;
  late RadioRepository radio;
  const seed = Track(
    id: 'seed',
    title: 'Seed Song',
    artist: 'Seed',
    album: 'Album',
    source: TrackSource.local,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-radio-source-');
    library = LibraryRepository(root);
    await library.load();
    metadata = _Metadata(DiskMediaCache(Directory('${root.path}/metadata')));
    similar = _Similar(metadata);
    indexer = _Indexer();
    torrents = _Torrents();
    catalog = RuTrackerService();
    radio = RadioRepository(
      library: library,
      torrents: torrents,
      metadata: metadata,
      similar: similar,
      indexer: indexer,
      catalog: catalog,
      random: Random(4),
    );
  });
  tearDown(() async {
    similar.dispose();
    metadata.dispose();
    indexer.dispose();
    torrents.dispose();
    await catalog.dispose();
    await library.flush();
    library.dispose();
    await root.delete(recursive: true);
  });
  test(
    'offline fallback is yielded and checked before public requests',
    () async {
      final file = File('${root.path}/song.wav');
      await file.writeAsBytes([1]);
      final local = Track(
        id: 'local',
        title: 'Local Song',
        artist: 'Seed',
        album: 'Album',
        source: TrackSource.local,
        localPath: file.path,
      );
      await library.upsert([local]);
      final operation = SourceOperation();
      final candidate = await radio.candidates([seed], {}, operation).first;
      expect(candidate.id, 'local');
      expect(metadata.calls, 0);
      final prepared = await radio.prepare(candidate, operation);
      expect(prepared.uri, Uri.file(file.path));
      expect(torrents.resolutions, 0);
      expect(indexer.searches, 0);
    },
  );
  test(
    'related library tracks work without a configured torrent indexer',
    () async {
      await library.setSetting('searchProvider', 'torznab');
      await library.upsert([
        const Track(
          id: 'related',
          title: 'Song',
          artist: 'Related',
          album: 'Album',
          source: TrackSource.local,
        ),
      ]);
      final result = await radio
          .candidates([seed], {}, SourceOperation())
          .toList();
      expect(result.map((t) => t.id), ['related']);
      expect(indexer.searches, 0);
      expect(torrents.uploads, 0);
    },
  );
  test(
    'radio ignores inspected albums and uses the played source album',
    () async {
      await library.setSetting('searchProvider', 'torznab');
      const played = Track(
        id: 'played',
        title: 'Played song',
        artist: 'Seed',
        album: 'Selected',
        source: TrackSource.torrent,
        torrentHash: 'found',
      );
      const sibling = Track(
        id: 'sibling',
        title: 'Sibling song',
        artist: 'Seed',
        album: 'Selected',
        source: TrackSource.torrent,
        torrentHash: 'found',
      );
      const other = Track(
        id: 'other',
        title: 'Other song',
        artist: 'Seed',
        album: 'Only inspected',
        source: TrackSource.torrent,
        torrentHash: 'found',
      );
      const related = Track(
        id: 'related',
        title: 'Related song',
        artist: 'Related',
        album: 'Only inspected related',
        source: TrackSource.torrent,
        torrentHash: 'found',
      );
      await library.openSourceCollection(
        hash: 'found',
        name: 'Found',
        tracks: [played, sibling, other, related],
      );
      expect(
        await radio.candidates([seed], {}, SourceOperation()).toList(),
        isEmpty,
      );
      await library.markPlayed(played.id);
      final excluded = {radioSongKey(played)};
      expect(
        (await radio.candidates([seed], excluded, SourceOperation()).toList())
            .map((t) => t.id),
        ['sibling'],
      );
      await library.toggleLike(related.id);
      expect(
        (await radio.candidates([seed], excluded, SourceOperation()).toList())
            .map((t) => t.id)
            .toSet(),
        {'sibling', 'related'},
      );
      expect(indexer.searches, 0);
      expect(torrents.uploads, 0);
    },
  );
  test(
    'bounded discovery rejects unrelated releases, skips bad metainfo and reuses cache',
    () async {
      await library.setSetting('indexerUrl', 'http://localhost/api');
      final found = await radio
          .candidates([seed], {}, SourceOperation())
          .toList();
      expect(found.length, 2);
      expect(indexer.queries, ['Related', 'Seed']);
      expect(indexer.links, ['https://index/broken', 'https://index/good']);
      expect(found.map((t) => t.torrentIndex).toSet(), {101, 102});
      expect(
        torrents.probes,
        0,
        reason: 'Discovering file names does not start audio',
      );
      final prepared = await radio.prepare(found.first, SourceOperation());
      expect(prepared.track.id, found.first.id);
      expect(torrents.resolvedIndexes, [found.first.torrentIndex]);
      expect(torrents.probeTimeout, const Duration(seconds: 8));
      await radio.candidates([seed], {}, SourceOperation()).toList();
      expect(indexer.links.where((link) => link.endsWith('/good')).length, 1);
      expect(
        indexer.links.where((link) => link.endsWith('/broken')).length,
        1,
        reason:
            'Bad metainfo is cooled down rather than fetched on each refill',
      );
      expect(
        torrents.uploads,
        2,
        reason: 'Restore actual engine file IDs on each inspection',
      );
      expect(
        await Directory('${root.path}/radio-search-temp').list().toList(),
        isEmpty,
      );
    },
  );
  test('empty payload is not admitted as a playable recommendation', () async {
    torrents.dead = true;
    const track = Track(
      id: 'torrent',
      title: 'Song',
      artist: 'Related',
      album: 'Album',
      source: TrackSource.torrent,
      torrentHash: 'hash',
      torrentIndex: 10,
    );
    await expectLater(
      radio.prepare(track, SourceOperation()),
      throwsA(isA<TimeoutException>()),
    );
    expect(torrents.probes, 1);
  });

  test(
    'direct catalogue retains the magnet for restoring the chosen file',
    () async {
      await library.setSetting('searchProvider', 'rutracker');
      await catalog.dispose();
      catalog = _DirectCatalog();
      radio = RadioRepository(
        library: library,
        torrents: torrents,
        metadata: metadata,
        similar: similar,
        indexer: indexer,
        catalog: catalog,
      );
      final result = await radio
          .candidates([seed], {}, SourceOperation())
          .toList();
      expect(result.single.torrentLink, 'magnet:?xt=urn:btih:direct');
      expect(result.single.torrentIndex, 177);
      expect(torrents.addedLinks, ['magnet:?xt=urn:btih:direct']);
      expect(indexer.searches, 0);
    },
  );
  test('missing metadata and deleted local files remain recoverable', () async {
    metadata.missing = true;
    expect(
      await radio.candidates([seed], {}, SourceOperation()).toList(),
      isEmpty,
    );
    await expectLater(
      radio.prepare(seed, SourceOperation()),
      throwsA(isA<FileSystemException>()),
    );
    final operation = SourceOperation()..cancel();
    await expectLater(
      radio.prepare(seed, operation),
      throwsA(isA<SourceCancelled>()),
    );
  });
}
