import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/data/windows_player_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/logic/playback_controller.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.mumpa/windows_player-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late LibraryRepository library;
  late PlaybackController playback;
  late TorrentService torrents;
  late FakeAudioBackend audio;
  late WindowsPlayerService service;
  late List<MethodCall> calls;
  late Future<void> Function() onQuit;

  Future<void> command(String action) async {
    final reply = Completer<void>();
    // Simulate a native shell callback through the real platform codec.
    // ignore: deprecated_member_use
    messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('command', action)),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  Future<void> flush() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-windows-player-');
    library = LibraryRepository(root);
    await library.load();
    final tracks = <Track>[];
    for (var i = 0; i < 2; i++) {
      final file = File('${root.path}/$i.wav');
      await file.writeAsBytes([1, 2, 3]);
      tracks.add(
        Track(
          id: '$i',
          title: 'Трек $i',
          artist: 'Артист',
          album: 'Альбом',
          source: TrackSource.local,
          localPath: file.path,
        ),
      );
    }
    await library.upsert(tracks);
    torrents = TorrentService(endpoint: () async => 'http://localhost:1');
    audio = FakeAudioBackend();
    playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
    );
    await playback.initialize(platformAudio: false);
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') {
        return {'smtc': true, 'tray': true, 'thumbnail': true};
      }
      return null;
    });
    onQuit = () async {};
    service = WindowsPlayerService(
      playback: playback,
      onQuit: () => onQuit(),
      channel: channel,
      enabled: true,
    );
    await service.initialize();
    await flush();
  });

  tearDown(() async {
    await service.close();
    messenger.setMockMethodCallHandler(channel, null);
    await playback.close();
    await library.flush();
    library.dispose();
    torrents.dispose();
    await root.delete(recursive: true);
  });

  test(
    'native media commands control the current queue and metadata',
    () async {
      await playback.playTracks(library.tracks);
      await command('pause');
      expect(playback.playing, isFalse);
      await command('play');
      expect(playback.playing, isTrue);
      await command('next');
      expect(playback.current!.id, '1');
      await flush();
      final state =
          calls.lastWhere((call) => call.method == 'updateState').arguments
              as Map;
      expect(state['title'], 'Трек 1');
      expect(state['artist'], 'Артист');
      expect(state['playing'], isTrue);
      expect(state['canNext'], isFalse);
      await command('previous');
      expect(playback.current!.id, '0');
      await command('toggle');
      expect(playback.playing, isFalse);
    },
  );

  test('position changes do not flood shell metadata updates', () async {
    await playback.playTracks(library.tracks);
    await flush();
    final before = calls.where((call) => call.method == 'updateState').length;
    await audio.seek(const Duration(seconds: 2));
    await audio.seek(const Duration(seconds: 3));
    await flush();
    expect(calls.where((call) => call.method == 'updateState').length, before);
  });

  test(
    'quit waits for cleanup and blocks media commands during shutdown',
    () async {
      await playback.playTracks(library.tracks);
      final cleanup = Completer<void>();
      var quitCount = 0;
      onQuit = () {
        quitCount++;
        return cleanup.future;
      };
      final quit = service.requestQuit();
      expect(service.requestQuit(), same(quit));
      await command('next');
      expect(playback.current!.id, '0');
      expect(calls.any((call) => call.method == 'quitReady'), isFalse);
      cleanup.complete();
      await quit;
      expect(quitCount, 1);
      expect(calls.last.method, 'quitReady');
    },
  );

  test('failed cleanup preserves the window and permits a retry', () async {
    onQuit = () async {
      throw StateError('fixture cleanup failure');
    };
    await expectLater(service.requestQuit(), throwsStateError);
    expect(calls.any((call) => call.method == 'quitReady'), isFalse);
    expect(calls.any((call) => call.method == 'quitFailed'), isTrue);
    onQuit = () async {};
    await service.requestQuit();
    expect(calls.last.method, 'quitReady');
  });

  test(
    'async close detaches native resources and further media commands',
    () async {
      await playback.playTracks(library.tracks);
      await service.close();
      expect(calls.last.method, 'dispose');
      expect(service.available, isFalse);
      await command('next');
      expect(playback.current!.id, '0');
    },
  );
}
