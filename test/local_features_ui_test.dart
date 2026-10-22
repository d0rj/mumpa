import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/local_tools.dart';
import 'package:mumpa/ui/app_screen.dart';
import 'package:mumpa/ui/lan_transfer_view.dart';
import 'package:mumpa/ui/lyrics_view.dart';
import 'package:path/path.dart' as p;
import 'support.dart';

final class _MovedFile extends PlatformFile {
  _MovedFile(this.file);
  final File file;
  @override
  String get name => file.uri.pathSegments.last;
  @override
  Uri get uri => file.uri;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MovedFilePicker extends FilePickerPlatform {
  _MovedFilePicker(this.file);
  final File file;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _MovedFile(file);
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => file.parent.path;
}

Future<void> settleFileIo(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

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
  for (final width in [320.0, 411.0]) {
    testWidgets('embedded settings scroll from the LAN form at $width px', (
      tester,
    ) async {
      final app = (await tester.runAsync(fixture))!;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 732);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        app.setSettingsSection('lanTransfer');
        await tester.pumpWidget(MumpaApp(controller: app));
        await tester.pumpAndSettle();
        final outer = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final before = outer.position.pixels;
        await tester.drag(
          find.text('Создать QR-код передачи'),
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();
        expect(outer.position.pixels, greaterThan(before + 30));
        final accept = find.text('Проверить и принять');
        await tester.ensureVisible(accept);
        await tester.tap(accept);
        await tester.pumpAndSettle();
        final error = find.text(
          'Нужна ссылка передачи Mumpa из локальной сети.',
        );
        await tester.ensureVisible(error);
        await tester.pumpAndSettle();
        expect(error.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await app.shutdown();
          app.library.dispose();
          await app.library.root.delete(recursive: true);
        });
      }
    });
  }
  testWidgets('new pairing link replaces the open LAN form once', (
    tester,
  ) async {
    final app = (await tester.runAsync(fixture))!;
    const first = 'mumpa-transfer://192.168.1.2:1234/#first';
    const second = 'mumpa-transfer://192.168.1.3:2345/#second';
    final field = find.descendant(
      of: find.byType(LanTransferView),
      matching: find.byType(TextField),
    );
    try {
      app.openTransferLink(first);
      await tester.pumpWidget(MumpaApp(controller: app));
      await tester.pumpAndSettle();
      expect(find.text(first), findsOneWidget);
      await tester.enterText(field, 'manual edit');
      await tester.pumpWidget(MumpaApp(controller: app));
      expect(find.text('manual edit'), findsOneWidget);
      app.openTransferLink(second);
      await tester.pumpAndSettle();
      expect(find.text(second), findsOneWidget);
      expect(find.text('manual edit'), findsNothing);
      await tester.enterText(field, 'another manual edit');
      app.openTransferLink(second);
      await tester.pumpAndSettle();
      expect(find.text(second), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await app.shutdown();
        app.library.dispose();
        await app.library.root.delete(recursive: true);
      });
    }
  });
  for (final folder in [false, true]) {
    testWidgets(
      'missing file list refreshes after ${folder ? 'folder' : 'manual'} repair',
      (tester) async {
        final app = (await tester.runAsync(fixture))!;
        final originalPicker = FilePickerPlatform.instance;
        try {
          final moved = (await tester.runAsync(() async {
            final old = File(app.library.tracks.single.localPath!);
            final destination = File('${app.library.root.path}/moved/a.wav');
            await destination.parent.create();
            await old.rename(destination.path);
            await app.library.toggleLike('a');
            final list = await app.library.createPlaylist('Keep references');
            await app.library.addToPlaylist(list.id, ['a']);
            return destination;
          }))!;
          FilePickerPlatform.instance = _MovedFilePicker(moved);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: LocalTools(app: app)),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.ensureVisible(find.text('Найти отсутствующие файлы'));
            await tester.tap(find.text('Найти отсутствующие файлы'));
          });
          await tester.pump(const Duration(milliseconds: 300));
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pumpAndSettle();
          expect(find.text('Song'), findsOneWidget);
          await tester.runAsync(() async {
            await tester.tap(find.text(folder ? 'Искать в папке' : 'Song'));
            await Future<void>.delayed(Duration.zero);
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (app.busy != null && DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
          await tester.pumpAndSettle();
          expect(app.error, isNull);
          if (folder) {
            await settleFileIo(
              tester,
              () => find.text('Найдено совпадений: 1').evaluate().isNotEmpty,
            );
            expect(find.text('Найдено совпадений: 1'), findsOneWidget);
            await tester.runAsync(() async {
              await tester.tap(find.text('Восстановить пути'));
              await Future<void>.delayed(Duration.zero);
              final deadline = DateTime.now().add(const Duration(seconds: 10));
              while (app.busy != null && DateTime.now().isBefore(deadline)) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
            });
            await tester.pumpAndSettle();
          }
          await tester.runAsync(() => app.library.flush());
          await tester.pumpAndSettle();
          await settleFileIo(
            tester,
            () => find.text('Song').evaluate().isEmpty,
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Song'), findsNothing);
          expect(
            p.normalize(app.library.byId('a')!.localPath!),
            p.normalize(moved.path),
          );
          expect(app.library.isTrackLiked('a'), isTrue);
          expect(app.library.playlists.single.trackIds, ['a']);
        } finally {
          FilePickerPlatform.instance = originalPicker;
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
