import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_share_link.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/music_share.dart';
import 'support.dart';

const hash = '0123456789abcdef0123456789abcdef01234567';
const info = TorrentInfo(
  hash: hash,
  title: 'Artist discography',
  files: [
    TorrentFile(
      index: 1,
      path: 'Artist/2020 - First/01 - Song.flac',
      bytes: 10,
    ),
    TorrentFile(index: 2, path: 'Artist/cover.jpg', bytes: 10),
    TorrentFile(
      index: 3,
      path: 'Artist/2020 - First/02 - Second.flac',
      bytes: 10,
    ),
    TorrentFile(
      index: 4,
      path: 'Artist/2021 - Other/01 - Other.flac',
      bytes: 10,
    ),
  ],
);

class ShareTorrents extends TorrentService {
  ShareTorrents() : super(endpoint: () async => throw StateError('No network'));
  final requested = <String>[];
  Completer<void>? gate;
  TorrentInfo response = info;
  @override
  Future<TorrentInfo> add(
    String link, {
    String? title,
    SourceOperation? operation,
    void Function(String)? onProgress,
  }) async {
    requested.add(link);
    if (gate != null) await gate!.future;
    operation?.check();
    return response;
  }
}

class ShareDownloads extends DownloadRepository {
  ShareDownloads(super.library, super.torrents);
  final requested = <Track>[];
  bool exactUsed = false;
  @override
  void enqueue(
    Iterable<Track> tracks, {
    bool priority = false,
    bool automatic = false,
    bool exact = false,
  }) {
    requested.addAll(tracks);
    exactUsed = exact;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppController app;
  late ShareTorrents torrents;
  late ShareDownloads downloads;
  late List<Track> tracks;

  MusicShareLink link(MusicShareKind kind, [List<Track>? selection]) =>
      MusicShareLink.fromTracks(
        selection ?? tracks,
        kind: kind,
        title: 'Альбом & музыка',
      )!;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-share-');
    final library = LibraryRepository(root);
    await library.load();
    await library.setSetting('autoCache', false);
    torrents = ShareTorrents();
    downloads = ShareDownloads(library, torrents);
    tracks = torrents.tracks(
      info,
      link: 'https://indexer.invalid/?apikey=SECRET',
    );
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    await playback.initialize(platformAudio: false);
    app = AppController(
      library: library,
      playback: playback,
      downloads: downloads,
      torrents: torrents,
      engine: TorrentEngine(root),
    );
  });
  tearDown(() async {
    await app.shutdown();
    app.library.dispose();
    await root.delete(recursive: true);
  });

  test(
    'all link types round-trip Cyrillic, exact indices and public identity',
    () {
      for (final kind in MusicShareKind.values) {
        final source = link(
          kind,
          kind == MusicShareKind.track ? [tracks.first] : tracks,
        );
        final parsed = MusicShareLink.parse(source.uri.toString());
        expect(parsed.kind, kind);
        expect(parsed.hash, hash);
        expect(parsed.indices, source.indices);
        expect(parsed.title, source.title);
        expect(parsed.uri.toString(), isNot(contains('SECRET')));
        expect(parsed.uri.toString(), isNot(contains('indexer')));
      }
    },
  );
  test('album ranges are compact and retain gaps and multiple discs', () {
    final range = link(MusicShareKind.album);
    expect(range.uri.queryParameters['files'], '1,3-4');
    expect(MusicShareLink.parse(range.uri.toString()).indices, {1, 3, 4});
    expect(link(MusicShareKind.release).uri.queryParameters['files'], isNull);
  });
  test('local files and mixed releases do not produce misleading links', () {
    const local = Track(
      id: 'local',
      title: 'Local',
      artist: '',
      album: '',
      source: TrackSource.local,
      localPath: 'C:/private/music.flac',
    );
    expect(
      MusicShareLink.fromTracks([local], kind: MusicShareKind.track, title: ''),
      isNull,
    );
    expect(
      link(MusicShareKind.track, [tracks.first]).uri.toString(),
      isNot(contains('private')),
    );
    expect(
      MusicShareLink.fromTracks(tracks, kind: MusicShareKind.track, title: ''),
      isNull,
    );
  });
  test('long emoji titles and control characters always yield valid links', () {
    final shared = MusicShareLink.fromTracks(
      [tracks.first],
      kind: MusicShareKind.track,
      title: '${'🎵' * 300}\nsecret',
    )!;
    expect(MusicShareLink.parse(shared.uri.toString()).title.runes.length, 240);
  });
  test(
    'malformed and oversized selections are rejected before network access',
    () async {
      final prefix = 'mumpa://share/v1?hash=$hash';
      for (final invalid in [
        '$prefix&kind=track',
        '$prefix&kind=unknown',
        '$prefix&kind=track&files=0',
        '$prefix&kind=track&files=-1',
        '$prefix&kind=track&files=1,3',
        '$prefix&kind=album&files=1-1000000',
        '$prefix&kind=album&files=4-1',
        '$prefix&kind=release&files=1',
        '$prefix&kind=track&files=1&files=4',
        '$prefix&kind=release&url=file:///x',
        '$prefix&kind=release&title=%00',
        '$prefix&kind=release#fragment',
        'mumpa://evil/v1?hash=$hash&kind=release',
        'mumpa://share/v2?hash=$hash&kind=release',
        '${prefix.replaceFirst(hash, '../unsafe')}&kind=release',
        '$prefix&kind=release&title=${'x' * 17000}',
      ]) {
        await app.openMusicLink(invalid);
        expect(
          app.error,
          isNotNull,
          reason: invalid.substring(0, invalid.length.clamp(0, 100)),
        );
      }
      expect(torrents.requested, isEmpty);
      expect(downloads.requested, isEmpty);
      expect(app.library.tracks, isEmpty);
      expect(app.error, isNot(contains('FormatException')));
    },
  );
  test(
    'new track imports and downloads only the requested exact file',
    () async {
      await app.openMusicLink(
        link(MusicShareKind.track, [tracks[1]]).uri.toString(),
      );
      expect(torrents.requested.single, 'magnet:?xt=urn:btih:$hash');
      expect(app.library.tracks.map((t) => t.torrentIndex), [3]);
      expect(downloads.requested.map((t) => t.torrentIndex), [3]);
      expect(downloads.exactUsed, isTrue);
      expect(app.album!.tracks.single.id, tracks[1].id);
      expect(app.playback.queue, isEmpty);
    },
  );
  test('album link from discography never downloads the other album', () async {
    await app.openMusicLink(
      link(MusicShareKind.album, tracks.take(2).toList()).uri.toString(),
    );
    expect(downloads.requested.map((t) => t.torrentIndex), [1, 3]);
    expect(app.album!.tracks.map((t) => t.torrentIndex), [1, 3]);
    expect(app.library.tracks.length, 2);
  });
  test(
    'release link imports every audio file and opens the collection',
    () async {
      await app.openMusicLink(link(MusicShareKind.release).uri.toString());
      expect(app.page, AppPage.playlist);
      expect(app.playlist!.sourceHash, hash);
      expect(app.playlistTracks.map((t) => t.torrentIndex), [1, 3, 4]);
      expect(downloads.requested.length, 3);
    },
  );
  test(
    'existing offline track opens without network or new downloads and keeps edits',
    () async {
      final file = await File('${root.path}/song.flac').writeAsBytes([1]);
      await app.library.upsert([
        tracks.first.copyWith(cachedPath: file.path, title: 'Edited'),
      ]);
      await app.openMusicLink(
        link(MusicShareKind.track, [tracks.first]).uri.toString(),
      );
      expect(torrents.requested, isEmpty);
      expect(downloads.requested, isEmpty);
      expect(app.album!.tracks.single.title, 'Edited');
      expect(app.message, contains('Уже скачано'));
    },
  );
  test(
    'offline collection opens without requesting torrent metadata',
    () async {
      final file = await File('${root.path}/song.flac').writeAsBytes([1]);
      await app.library.openSourceCollection(
        hash: hash,
        name: info.title,
        tracks: tracks.map((t) => t.copyWith(cachedPath: file.path)).toList(),
      );
      await app.openMusicLink(link(MusicShareKind.release).uri.toString());
      expect(app.page, AppPage.playlist);
      expect(torrents.requested, isEmpty);
      expect(downloads.requested, isEmpty);
    },
  );
  test(
    'partial offline album downloads missing files and keeps cached path',
    () async {
      final file = await File('${root.path}/song.flac').writeAsBytes([1]);
      await app.library.upsert([
        tracks.first.copyWith(cachedPath: file.path),
        tracks[1],
      ]);
      await app.openMusicLink(
        link(MusicShareKind.album, tracks.take(2).toList()).uri.toString(),
      );
      expect(torrents.requested, isEmpty);
      expect(downloads.requested.map((t) => t.torrentIndex), [3]);
      expect(app.library.byId(tracks.first.id)!.cachedPath, file.path);
    },
  );
  test('deleted cached file is cleared and queued for download', () async {
    await app.library.upsert([
      tracks.first.copyWith(cachedPath: '${root.path}/gone.flac'),
    ]);
    await app.openMusicLink(
      link(MusicShareKind.track, [tracks.first]).uri.toString(),
    );
    expect(app.library.byId(tracks.first.id)!.cachedPath, isNull);
    expect(downloads.requested.single.id, tracks.first.id);
  });
  test('missing file index and wrong hash never mutate the library', () async {
    await app.openMusicLink('mumpa://share/v1?hash=$hash&kind=track&files=42');
    expect(app.error, isNotNull);
    expect(app.library.tracks, isEmpty);
    torrents.response = const TorrentInfo(
      hash: 'ffffffffffffffffffffffffffffffffffffffff',
      title: '',
      files: [],
    );
    await app.openMusicLink(
      link(MusicShareKind.track, [tracks.first]).uri.toString(),
    );
    expect(app.error, contains('не соответствует'));
    expect(downloads.requested, isEmpty);
  });
  test(
    'second link during metadata lookup is processed after the first',
    () async {
      torrents.gate = Completer<void>();
      final first = app.openMusicLink(
        link(MusicShareKind.track, [tracks.first]).uri.toString(),
      );
      final second = app.openMusicLink(
        link(MusicShareKind.track, [tracks.last]).uri.toString(),
      );
      await Future<void>.delayed(Duration.zero);
      torrents.gate!.complete();
      await Future.wait([first, second]);
      expect(downloads.requested.map((t) => t.torrentIndex), [1, 4]);
      expect(app.album!.tracks.single.torrentIndex, 4);
    },
  );
  test(
    'cold startup arguments and warm channel activations both open music',
    () async {
      final channel = const MethodChannel('app.mumpa/links');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => <String>[]);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await app.initializeMusicLinks([
        link(MusicShareKind.track, [tracks.first]).uri.toString(),
      ]);
      // Await a sentinel on the same serialized queue.
      await app.openMusicLink(
        link(MusicShareKind.track, [tracks.first]).uri.toString(),
      );
      final codec = const StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'app.mumpa/links',
            codec.encodeMethodCall(
              MethodCall(
                'open',
                link(MusicShareKind.track, [tracks.last]).uri.toString(),
              ),
            ),
            (_) {},
          );
      await app.openMusicLink(
        link(MusicShareKind.track, [tracks.last]).uri.toString(),
      );
      expect(app.album!.tracks.single.torrentIndex, 4);
    },
  );
  testWidgets('share dialog copies parseable link at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicShareButton(
            app: app,
            tracks: tracks.take(2).toList(),
            kind: MusicShareKind.album,
            title: 'Альбом',
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('share-album')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('music-share-link')), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy-music-link')));
    await tester.pumpAndSettle();
    expect(MusicShareLink.parse(copied!).indices, {1, 3});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
