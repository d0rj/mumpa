import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/torrent_album_layout.dart';

TorrentInfo _info(List<String> paths, {String title = 'Band - Discography'}) =>
    TorrentInfo(
      hash: 'public-fixture-hash',
      title: title,
      files: [
        for (var index = 0; index < paths.length; index++)
          TorrentFile(index: index + 7, path: paths[index], bytes: 100),
      ],
    );

Future<File> _taggedFlac(
  Directory root,
  String name, {
  String album = 'Tagged Album',
  String albumArtist = 'Album Band',
  String artist = 'Guest Artist',
}) async {
  // Original metadata-only FLAC fixture; no external music or network I/O.
  List<int> uint32(int number, {Endian endian = Endian.big}) =>
      (ByteData(4)..setUint32(0, number, endian)).buffer.asUint8List();
  List<int> block(int type, List<int> bytes, {bool last = false}) => [
    type | (last ? 128 : 0),
    (bytes.length >> 16) & 255,
    (bytes.length >> 8) & 255,
    bytes.length & 255,
    ...bytes,
  ];
  final stream = Uint8List(34);
  ByteData.sublistView(
    stream,
  ).setUint64(10, (44100 << 44) | (15 << 36) | 44100);
  final comments = [
    'ALBUM=$album',
    'ALBUMARTIST=$albumArtist',
    'ARTIST=$artist',
    'TITLE=Embedded title',
    'TRACKNUMBER=2',
    'DISCNUMBER=1',
    'DATE=2001',
    'LYRICS=Original fixture lyrics',
  ].map(utf8.encode).toList();
  final vendor = utf8.encode('Mumpa original fixture');
  final vorbis = [
    ...uint32(vendor.length, endian: Endian.little),
    ...vendor,
    ...uint32(comments.length, endian: Endian.little),
    for (final comment in comments) ...[
      ...uint32(comment.length, endian: Endian.little),
      ...comment,
    ],
  ];
  final image = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1kAAAAASUVORK5CYII=',
  );
  final mime = utf8.encode('image/png');
  final picture = [
    ...uint32(3),
    ...uint32(mime.length),
    ...mime,
    ...uint32(0),
    ...uint32(1),
    ...uint32(1),
    ...uint32(8),
    ...uint32(0),
    ...uint32(image.length),
    ...image,
  ];
  final file = File('${root.path}/$name');
  await file.writeAsBytes([
    ...utf8.encode('fLaC'),
    ...block(0, stream),
    ...block(4, vorbis),
    ...block(6, picture, last: true),
  ]);
  return file;
}

Future<File> _taggedMp3(Directory root) async {
  List<int> syncsafe(int size) => [
    (size >> 21) & 127,
    (size >> 14) & 127,
    (size >> 7) & 127,
    size & 127,
  ];
  List<int> frame(String id, List<int> payload) => [
    ...ascii.encode(id),
    ...syncsafe(payload.length),
    0,
    0,
    ...payload,
  ];
  final body = [
    for (final entry in {
      'TIT2': 'Original ID3 track',
      'TALB': 'ID3 Compilation',
      'TPE1': 'Исполнитель трека',
      'TPE2': 'Various Artists',
      'TRCK': '2/10',
      'TPOS': '1/2',
      'TYER': '2004',
    }.entries)
      ...frame(entry.key, [3, ...utf8.encode(entry.value)]),
    ...frame('USLT', [
      3,
      ...ascii.encode('eng'),
      0,
      ...utf8.encode('Original ID3 lyrics'),
    ]),
  ];
  final file = File('${root.path}/original-id3.mp3');
  await file.writeAsBytes([
    ...ascii.encode('ID3'),
    4,
    0,
    0,
    ...syncsafe(body.length),
    ...body,
  ]);
  return file;
}

Future<File> _taggedM4a(
  Directory root, {
  bool oversizedCredit = false,
  bool omitMetaFlags = false,
}) async {
  List<int> number(int value) =>
      (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
  List<int> atom(String type, List<int> payload) => [
    ...number(payload.length + 8),
    ...latin1.encode(type),
    ...payload,
  ];
  List<int> text(String type, String value, {bool utf16 = false}) {
    final bytes = utf16
        ? [
            for (final unit in value.codeUnits) ...[
              (unit >> 8) & 255,
              unit & 255,
            ],
          ]
        : utf8.encode(value);
    return atom(
      type,
      atom('data', [...number(utf16 ? 2 : 1), ...number(0), ...bytes]),
    );
  }

  final credits = [
    ...text('©nam', 'Original M4A track'),
    ...text('©alb', 'M4A Compilation'),
    ...text('©ART', 'Исполнитель трека'),
    ...text(
      'aART',
      oversizedCredit ? List.filled(65537, 'x').join() : 'Артисты альбома',
      utf16: !oversizedCredit,
    ),
    ...text('©lyr', 'Original M4A lyrics'),
  ];
  final metadata = atom(
    'moov',
    atom(
      'udta',
      atom('meta', [
        if (!omitMetaFlags) ...number(0),
        ...atom('ilst', credits),
      ]),
    ),
  );
  final file = File(
    '${root.path}/original-credits${oversizedCredit ? '-large' : ''}${omitMetaFlags ? '-qt' : ''}.m4a',
  );
  final handle = file.openSync(mode: FileMode.write);
  try {
    handle.writeFromSync(
      atom('ftyp', [
        ...ascii.encode('M4A '),
        ...number(0),
        ...ascii.encode('isom'),
      ]),
    );
    // Sparse original media body verifies that metadata after mdat is reached
    // without allocating/reading that payload into the supplemental adapter.
    const payloadSize = 8 * 1024 * 1024;
    handle.writeFromSync([...number(payloadSize + 8), ...ascii.encode('mdat')]);
    handle.setPositionSync(handle.positionSync() + payloadSize);
    handle.writeFromSync(metadata);
  } finally {
    handle.closeSync();
  }
  return file;
}

void main() {
  late Directory root;
  late LibraryRepository library;
  late TorrentService torrents;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-discography-');
    library = LibraryRepository(root);
    await library.load();
    torrents = TorrentService(endpoint: () async => 'http://localhost');
  });
  tearDown(() async {
    await library.flush();
    library.dispose();
    torrents.dispose();
    await root.delete(recursive: true);
  });

  test(
    'album directories ignore codec and CD wrappers but preserve torrent IDs',
    () {
      final info = _info([
        'Root/Band/1999 - First/FLAC/CD1/01 - One.flac',
        'Root/Band/1999 - First/MP3/Disc 2/01 - Two.mp3',
        'Root/Band/2003 - Second/CD1/02 - Three.flac',
        'Root/Band/2003 - Second/cover.jpg',
      ]);
      final tracks = torrents.tracks(info);
      expect(tracks.map((track) => track.album), ['First', 'First', 'Second']);
      expect(tracks.map((track) => track.disc), [1, 2, 1]);
      expect(tracks.map((track) => track.year), [1999, 1999, 2003]);
      expect(tracks.first.artist, 'Band');
      expect(tracks.first.torrentAlbumPath, tracks[1].torrentAlbumPath);
      expect(tracks.first.id, stableId('${info.hash}:7'));
      expect(tracks.map((track) => track.torrentIndex), [7, 8, 9]);
      expect(groupAlbums(tracks).length, 2);
    },
  );

  test(
    'numbered Cyrillic folders and filenames retain album year and track number',
    () {
      final track = torrents
          .tracks(
            _info([
              'ежемесячные - Дискография/[68] (2025) Короли Абстракта VI - Мультивселенная ЕЖЕ (EP)/11. Роженица в метро.mp3',
            ], title: 'Ежемесячные - Дискография'),
          )
          .single;
      expect(track.album, 'Короли Абстракта VI - Мультивселенная ЕЖЕ');
      expect(track.year, 2025);
      expect(track.number, 11);
      expect(track.title, 'Роженица в метро');
      expect(track.artist.toLowerCase(), 'ежемесячные');
    },
  );

  test(
    'category wrappers and WEB AAC do not become albums; disc-track prefix works',
    () {
      final tracks = torrents.tracks(
        _info([
          'Paul McCartney (WEB AAC)/Albums/Classical/1991 - Liverpool Oratorio/WEB AAC/1-01 Liverpool Oratorio.m4a',
          'Paul McCartney (WEB AAC)/McCartney Archive Collection/1991 - Liverpool Oratorio/AAC/2-01 Second act.m4a',
          "Paul McCartney (WEB AAC)/Singles & EP's/2000 - Single (Deluxe Edition)/01 - Song.m4a",
        ], title: 'Paul McCartney - Discography'),
      );
      expect(tracks.take(2).map((track) => track.album), [
        'Liverpool Oratorio',
        'Liverpool Oratorio',
      ]);
      expect(tracks.take(2).map((track) => track.disc), [1, 2]);
      expect(tracks.first.number, 1);
      expect(tracks.first.title, 'Liverpool Oratorio');
      expect(tracks.first.torrentAlbumPath, tracks[1].torrentAlbumPath);
      expect(tracks.last.album, 'Single (Deluxe Edition)');
    },
  );

  test(
    'flat ordinary release uses release identity rather than its root directory',
    () {
      final track = torrents
          .tracks(
            _info([
              'Release Root/FLAC/CD2/03 - Song.flac',
            ], title: 'Band - Album, 2002, FLAC'),
          )
          .single;
      expect(track.album, 'Album');
      expect(track.artist, 'Band');
      expect(track.disc, 2);
      expect(track.year, 2002);
      expect(track.torrentAlbumPath, '');
      expect(track.albumSource, TrackAlbumSource.release);
      expect(parseTorrentTrackName('2-03 Song.flac'), (
        title: 'Song',
        number: 3,
        disc: 2,
      ));
    },
  );

  test('ISO dates and named category wrappers preserve real album leaves', () {
    final tracks = torrents.tracks(
      _info([
        'Root/Band/Альбомы/2019-10-25 ОТТЕНКИ БАРДА (Mixtape)/01 - Song.flac',
        'Root/Band/Mixtapes/2019 - ОТТЕНКИ БАРДА/02 - Song.flac',
        'Root/Band/+EP/2020 - Short/01 - Song.flac',
        'Root/Band/+Singles/2021 - Single/01 - Song.flac',
        'Root/Band/Album/CD1/01 - Plain.flac',
      ]),
    );
    expect(tracks.take(2).map((track) => track.album), [
      'ОТТЕНКИ БАРДА',
      'ОТТЕНКИ БАРДА',
    ]);
    expect(tracks.take(2).map((track) => track.year), [2019, 2019]);
    expect(tracks[2].album, 'Short');
    expect(tracks[3].album, 'Single');
    expect(tracks[4].album, 'Album');
    expect(tracks[4].torrentAlbumPath, 'Band/Album');
  });

  test(
    'leaf trackography and leaf mixed categories never propagate one tagged album',
    () async {
      final tracks = torrents.tracks(
        _info([
          'Root/Band/Трекография/01 - One.flac',
          'Root/Band/Трекография/02 - Two.flac',
        ], title: 'Band - Трекография'),
      );
      expect(tracks.map((track) => track.album), [
        'Band - Трекография',
        'Band - Трекография',
      ]);
      expect(tracks.every((track) => track.torrentAlbumPath == null), isTrue);
      await library.upsert(tracks);
      await library.upsert([
        tracks.first.copyWith(
          album: 'One real album',
          albumSource: TrackAlbumSource.tags,
          albumArtistFromTags: true,
        ),
      ]);
      expect(library.byId(tracks.last.id)!.album, 'Band - Трекография');
      for (final category in ['+EP', '+Singles', 'Альбомы', 'Mixtapes']) {
        final track = torrents
            .tracks(_info(['Root/Band/$category/01 - Song.flac']))
            .single;
        expect(track.torrentAlbumPath, isNull, reason: category);
        expect(track.album, 'Band - Discography', reason: category);
      }
    },
  );

  test(
    'legacy migration preserves favorites, playlist identity and enriched cache metadata',
    () async {
      final cached = File('${root.path}/cached.flac');
      await cached.writeAsBytes([0, 0, 0]);
      const paths = [
        'Root/Band/1999 - First/CD2/01 - A.flac',
        'Root/Band/2000 - Second/01 - B.flac',
      ];
      final old = [
        for (var index = 0; index < paths.length; index++)
          Track(
            id: 'old-$index',
            title: index == 0 ? 'Previously enriched' : 'B',
            artist: 'Band',
            albumArtist: 'Band',
            album: 'Band - Discography',
            source: TrackSource.torrent,
            torrentHash: 'legacy',
            torrentIndex: index + 5,
            torrentPath: paths[index],
            cachedPath: index == 0 ? cached.path : null,
            artPath: index == 0 ? 'existing-art.jpg' : null,
            lyrics: index == 0 ? 'existing lyrics' : null,
          ),
      ];
      await File('${root.path}/library.json').writeAsString(
        jsonEncode({
          'tracks': old.map((track) => track.toJson()).toList(),
          'liked': ['old-0'],
          'recent': ['old-0'],
          'playlists': [
            const MusicPlaylist(
              id: 'unchanged-list',
              name: 'Band - Discography',
              sourceHash: 'legacy',
              trackIds: ['old-1', 'old-0'],
            ).toJson(),
          ],
          'settings': {
            'playback': {
              'ids': ['old-0'],
              'index': 0,
              'position': 7000,
            },
          },
        }),
      );
      final fresh = LibraryRepository(root);
      await fresh.load();
      expect(fresh.tracks.map((track) => track.album), ['First', 'Second']);
      expect(fresh.byId('old-0')!.disc, 2);
      expect(fresh.byId('old-0')!.title, 'Previously enriched');
      expect(fresh.byId('old-0')!.artPath, 'existing-art.jpg');
      expect(fresh.byId('old-0')!.lyrics, 'existing lyrics');
      expect(fresh.byId('old-0')!.cachedPath, cached.path);
      expect(fresh.liked, {'old-0'});
      expect(fresh.recent, ['old-0']);
      expect(fresh.playlists.single.id, 'unchanged-list');
      expect(fresh.playlists.single.trackIds, ['old-1', 'old-0']);
      expect((fresh.settings['playback'] as Map)['position'], 7000);
      final saved = await File('${root.path}/library.json').readAsString();
      fresh.dispose();
      final again = LibraryRepository(root);
      await again.load();
      expect(await File('${root.path}/library.json').readAsString(), saved);
      again.dispose();
    },
  );

  test('MP3 TPE1 and TPE2 remain separate track and album credits', () async {
    final tracks = torrents.tracks(
      _info([
        'Root/Band/1999 - Folder/01 - One.mp3',
        'Root/Band/1999 - Folder/02 - Two.mp3',
      ]),
    );
    await library.upsert(tracks);
    final file = await _taggedMp3(root);
    final tagged = await library.inspect(file.path, torrent: tracks.first);
    expect(tagged.title, 'Original ID3 track');
    expect(tagged.album, 'ID3 Compilation');
    expect(tagged.artist, 'Исполнитель трека');
    expect(tagged.albumArtist, 'Various Artists');
    expect(tagged.albumArtistFromTags, isTrue);
    expect(tagged.lyrics, 'Original ID3 lyrics');
    expect(tagged.number, 2);
    await library.upsert([tagged]);
    expect(library.byId(tracks.last.id)!.albumArtist, 'Various Artists');
    expect(groupAlbums(library.tracks).length, 1);
    final local = await library.inspect(file.path);
    expect(local.artist, 'Исполнитель трека');
    expect(local.albumArtist, 'Various Artists');
  });

  test(
    'M4A ©ART and UTF16 aART retain distinct credits across fullbox and QuickTime meta',
    () async {
      for (final omitFlags in [false, true]) {
        final file = await _taggedM4a(root, omitMetaFlags: omitFlags);
        final track = torrents
            .tracks(_info(['Root/Band/1999 - Folder/01 - One.m4a']))
            .single;
        final tagged = await library.inspect(file.path, torrent: track);
        expect(tagged.title, 'Original M4A track');
        expect(tagged.album, 'M4A Compilation');
        expect(tagged.artist, 'Исполнитель трека');
        expect(tagged.albumArtist, 'Артисты альбома');
        expect(tagged.albumArtistFromTags, isTrue);
        expect(tagged.lyrics, 'Original M4A lyrics');
      }
    },
  );

  test(
    'oversized supplemental M4A credit is skipped without discarding valid tags',
    () async {
      final file = await _taggedM4a(root, oversizedCredit: true);
      final track = torrents
          .tracks(_info(['Root/Band/1999 - Folder/01 - One.m4a']))
          .single;
      final tagged = await library.inspect(file.path, torrent: track);
      expect(tagged.album, 'M4A Compilation');
      expect(tagged.artist, 'Исполнитель трека');
      expect(tagged.albumArtist, 'Band');
      expect(tagged.albumArtistFromTags, isFalse);
    },
  );

  test('albumArtist-only tags preserve one confident album group', () async {
    final tracks = torrents.tracks(
      _info([
        'Root/Band/1999 - Compilation/01 - One.flac',
        'Root/Band/1999 - Compilation/02 - Two.flac',
      ]),
    );
    await library.upsert(tracks);
    final file = await _taggedFlac(
      root,
      'artist-only.flac',
      album: '',
      albumArtist: 'Various Artists',
    );
    final enriched = await library.inspect(file.path, torrent: tracks.first);
    expect(enriched.album, 'Compilation');
    expect(enriched.albumArtistFromTags, isTrue);
    expect(enriched.artist, 'Guest Artist');
    await library.upsert([enriched]);
    expect(library.tracks.map((track) => track.album), [
      'Compilation',
      'Compilation',
    ]);
    expect(library.tracks.map((track) => track.albumArtist), [
      'Various Artists',
      'Various Artists',
    ]);
    expect(groupAlbums(library.tracks).length, 1);
  });

  test(
    'full-file album tags update every unread album sibling atomically',
    () async {
      final info = _info([
        'Root/Band/1999 - Folder Album/CD1/01 - One.flac',
        'Root/Band/1999 - Folder Album/CD2/01 - Two.flac',
        'Root/Band/2000 - Other/01 - Three.flac',
      ]);
      final tracks = torrents.tracks(info);
      await library.openSourceCollection(
        hash: info.hash,
        name: info.title,
        tracks: tracks,
      );
      final file = await _taggedFlac(root, 'complete.flac');
      final enriched = await library.inspect(file.path, torrent: tracks.first);
      expect(enriched.album, 'Tagged Album');
      expect(enriched.albumArtist, 'Album Band');
      expect(enriched.artist, 'Guest Artist');
      expect(enriched.albumSource, TrackAlbumSource.tags);
      expect(enriched.albumArtistFromTags, isTrue);
      expect(enriched.lyrics, 'Original fixture lyrics');
      expect(await File(enriched.artPath!).exists(), isTrue);
      final observations = <List<String>>[];
      library.addListener(
        () => observations.add(
          library.tracks.take(2).map((track) => track.album).toList(),
        ),
      );
      await library.upsert([enriched]);
      expect(observations.single, ['Tagged Album', 'Tagged Album']);
      expect(library.byId(tracks[1].id)!.albumArtist, 'Album Band');
      expect(library.byId(tracks[1].id)!.disc, 2);
      expect(library.byId(tracks[2].id)!.album, 'Other');
      expect(groupAlbums(library.tracks).length, 2);
      await library.openSourceCollection(
        hash: info.hash,
        name: info.title,
        tracks: tracks,
      );
      expect(library.byId(tracks.first.id)!.title, 'Embedded title');
      expect(library.byId(tracks.first.id)!.cachedPath, file.path);
      expect(library.byId(tracks[1].id)!.album, 'Tagged Album');
      await library.upsert(tracks);
      expect(library.byId(tracks.first.id)!.title, 'Embedded title');
      expect(library.byId(tracks.first.id)!.album, 'Tagged Album');
      expect(library.byId(tracks.first.id)!.cachedPath, file.path);
    },
  );

  test(
    'flat mixed collection tags never relabel unread files or override other explicit albums',
    () async {
      final tracks = torrents.tracks(
        _info([
          'Mixed/01 - One.flac',
          'Mixed/02 - Two.flac',
          'Mixed/03 - Unread.flac',
        ], title: 'VA - Collection'),
      );
      expect(tracks.every((track) => track.torrentAlbumPath == null), isTrue);
      await library.upsert(tracks);
      final first = await _taggedFlac(root, 'first.flac', album: 'First Album');
      final second = await _taggedFlac(
        root,
        'second.flac',
        album: 'Second Album',
      );
      await library.upsert([
        await library.inspect(first.path, torrent: tracks[0]),
      ]);
      expect(library.byId(tracks[1].id)!.album, 'VA - Collection');
      await library.upsert([
        await library.inspect(second.path, torrent: tracks[1]),
      ]);
      expect(library.byId(tracks[0].id)!.album, 'First Album');
      expect(library.byId(tracks[1].id)!.album, 'Second Album');
      expect(library.byId(tracks[2].id)!.album, 'VA - Collection');
      expect(groupAlbums(library.tracks).length, 3);
    },
  );

  test(
    'conflicting explicit tags survive sibling propagation and JSON restart',
    () async {
      final tracks = torrents.tracks(
        _info([
          'Root/Band/1999 - Album/01 - One.flac',
          'Root/Band/1999 - Album/02 - Two.flac',
          'Root/Band/1999 - Album/03 - Three.flac',
        ]),
      );
      await library.upsert(tracks);
      final first = tracks[0].copyWith(
        album: 'Canonical',
        albumArtist: 'Various Artists',
        albumSource: TrackAlbumSource.tags,
        albumArtistFromTags: true,
      );
      final second = tracks[1].copyWith(
        album: 'Explicit Other',
        albumArtist: 'Explicit Artist',
        albumSource: TrackAlbumSource.tags,
        albumArtistFromTags: true,
      );
      await library.upsert([first, second]);
      expect(library.byId(tracks[2].id)!.album, 'Canonical');
      expect(library.byId(tracks[2].id)!.albumArtist, 'Various Artists');
      expect(library.byId(tracks[1].id)!.album, 'Explicit Other');
      final fresh = LibraryRepository(root);
      await fresh.load();
      expect(fresh.byId(tracks[1].id)!.albumArtist, 'Explicit Artist');
      expect(fresh.byId(tracks[1].id)!.albumSource, TrackAlbumSource.tags);
      expect(
        fresh.byId(tracks[2].id)!.torrentAlbumPath,
        tracks[2].torrentAlbumPath,
      );
      fresh.dispose();
    },
  );

  test(
    'legacy cached tags are read once and propagated within their album folder',
    () async {
      final cached = await _taggedFlac(
        root,
        'old-cache.flac',
        album: 'Original embedded album',
      );
      final old = [
        for (var index = 0; index < 2; index++)
          Track(
            id: 'legacy-tag-$index',
            title: 'Old $index',
            artist: 'Band',
            album: 'Band - Discography',
            source: TrackSource.torrent,
            torrentHash: 'legacy-tags',
            torrentIndex: index + 1,
            torrentPath: 'Root/Band/1999 - Folder/${index + 1} - Track.flac',
            cachedPath: index == 0 ? cached.path : null,
          ),
      ];
      await File('${root.path}/library.json').writeAsString(
        jsonEncode({'tracks': old.map((track) => track.toJson()).toList()}),
      );
      final migrated = LibraryRepository(root);
      await migrated.load();
      expect(migrated.tracks.map((track) => track.album), [
        'Original embedded album',
        'Original embedded album',
      ]);
      expect(migrated.tracks.first.albumSource, TrackAlbumSource.tags);
      expect(migrated.tracks.last.albumSource, TrackAlbumSource.sibling);
      expect(migrated.tracks.last.albumArtist, 'Album Band');
      migrated.dispose();
      await _taggedFlac(
        root,
        'old-cache.flac',
        album: 'Changed after migration',
      );
      final fresh = LibraryRepository(root);
      await fresh.load();
      expect(fresh.tracks.first.album, 'Original embedded album');
      expect(fresh.tracks.last.album, 'Original embedded album');
      fresh.dispose();
    },
  );
}
