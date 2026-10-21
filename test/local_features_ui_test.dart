import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/local_tools.dart';
import 'package:mumpa/ui/lan_transfer_view.dart';
import 'package:mumpa/ui/lyrics_view.dart';
import 'support.dart';

Future<AppController> fixture() async {
  final root = await Directory.systemTemp.createTemp('mumpa-local-ui-');
  final library = LibraryRepository(root);
  await library.load();
  final path = '${root.path}/a.wav';
  await File(path).writeAsBytes([1, 2, 3]);
  final track = Track(
    id: 'a',
    title: 'Song',
    artist: 'Band',
    album: 'Album',
    source: TrackSource.local,
    localPath: path,
    lyrics: '[00:00]First\n[00:05]Second\n[00:10]Third',
  );
  await library.upsert([track]);
  final source = TorrentService(endpoint: () async => 'http://127.0.0.1:1');
  final player = PlaybackController(
    library: library,
    torrents: source,
    backend: FakeAudioBackend(),
  );
  await player.initialize(platformAudio: false);
  return AppController(
    library: library,
    playback: player,
    downloads: DownloadRepository(library, source),
    torrents: source,
    engine: TorrentEngine(root),
  );
}

void main() {
  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'new tools, statistics and LAN form fit $width px and smart rules save',
      (tester) async {
        final app = (await tester.runAsync(fixture))!;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 700);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(),
              home: Scaffold(body: LocalTools(app: app)),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Умный плейлист'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Только любимое'));
          await tester.pump();
          await tester.runAsync(() async {
            await tester.tap(find.text('Сохранить'));
            await app.library.flush();
          });
          await tester.pumpAndSettle();
          expect(app.library.playlists.single.isSmart, isTrue);
          expect(app.library.playlists.single.smartRule!['liked'], isTrue);
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(),
              home: Scaffold(body: ListeningStatistics(app: app)),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Календарь прослушиваний'), findsOneWidget);
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(),
              home: Scaffold(body: LanTransferView(app: app)),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Создать QR-код передачи'), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await app.shutdown();
            app.library.dispose();
            await app.library.root.delete(recursive: true);
          });
        }
      },
    );
  }
  testWidgets(
    'synchronized lyrics highlight and seek without replacing the queue',
    (tester) async {
      final app = (await tester.runAsync(fixture))!;
      try {
        await tester.runAsync(
          () => app.playback.playTracks(app.library.tracks),
        );
        final queue = app.playback.queueEntryKeys;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(body: LyricsView(app: app)),
          ),
        );
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('lyric-line-1')), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('lyric-line-1')));
          await app.library.flush();
        });
        await tester.pumpAndSettle();
        expect(app.playback.position.inSeconds, 5);
        expect(app.playback.queueEntryKeys, queue);
        expect(app.playback.current!.id, 'a');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await app.shutdown();
          app.library.dispose();
          await app.library.root.delete(recursive: true);
        });
      }
    },
  );
  test(
    'Android Auto browses local categories, searches, and plays the chosen collection',
    () async {
      final app = await fixture();
      try {
        await app.library.toggleLike('a');
        final list = await app.library.createPlaylist('Car playlist');
        await app.library.addToPlaylist(list.id, ['a']);
        final handler = SystemAudioHandler(app.playback);
        final playlists = await handler.getChildren('playlists');
        expect(playlists.map((i) => i.id), contains('playlist:${list.id}'));
        expect((await handler.getChildren('liked')).single.id, 'a');
        expect((await handler.search('band song')).single.id, 'a');
        await handler.playFromMediaId('playlist:${list.id}');
        expect(app.playback.current!.id, 'a');
        expect(app.playback.contextPlaylistId, list.id);
        await handler.pause();
        expect(app.playback.playing, isFalse);
        await handler.play();
        expect(app.playback.playing, isTrue);
      } finally {
        await app.shutdown();
        app.library.dispose();
        await app.library.root.delete(recursive: true);
      }
    },
  );
  test(
    'Android Auto continuation exposes collections beyond the first 200',
    () async {
      final app = await fixture();
      try {
        final file = File('${app.library.root.path}/library.json');
        final snapshot =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        snapshot['playlists'] = [
          for (var i = 0; i < 240; i++)
            MusicPlaylist(
              id: 'playlist-$i',
              name: 'Playlist $i',
              trackIds: ['a'],
            ).toJson(),
        ];
        await file.writeAsString(jsonEncode(snapshot));
        await app.library.load();
        final handler = SystemAudioHandler(app.playback);
        final first = await handler.getChildren('playlists');
        expect(first.length, 201);
        expect(first.last.playable, isFalse);
        final rest = await handler.getChildren(first.last.id);
        expect(rest.length, 41);
        expect(rest.last.id, 'playlist:playlist-239');
      } finally {
        await app.shutdown();
        app.library.dispose();
        await app.library.root.delete(recursive: true);
      }
    },
  );
}
