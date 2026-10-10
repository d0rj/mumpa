import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/flaresolverr_service.dart';
import 'package:mumpa/data/jackett_service.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/rutracker_service.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/data/windows_player_service.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';

import 'support.dart';

// Errors deliberately contain private-looking data; diagnostics must omit it.
const _privateError = 'https://private.invalid/?apikey=never-log-this';

class _FailingLibrary extends LibraryRepository {
  _FailingLibrary(super.root, this.events);
  final List<String> events;
  bool failSave = false, failFlush = false;

  @override
  Future<void> setSetting(String key, dynamic value) async {
    if (key == 'playback') {
      events.add('save');
      if (failSave) throw StateError(_privateError);
    }
    await super.setSetting(key, value);
  }

  @override
  Future<void> flush() async {
    events.add('flush');
    if (failFlush) throw StateError(_privateError);
    await super.flush();
  }
}

class _FailingAudio extends FakeAudioBackend {
  _FailingAudio(this.events);
  final List<String> events;
  final closing = Completer<void>();
  Completer<void>? gate;
  bool failClose = false;

  @override
  Future<void> close() async {
    events.add('audio');
    closing.complete();
    await gate?.future;
    await super.close();
    if (failClose) throw StateError(_privateError);
  }
}

class _RecordingTorrents extends TorrentService {
  _RecordingTorrents(this.events)
    : super(endpoint: () async => 'http://127.0.0.1:1');
  final List<String> events;
  @override
  void dispose() {
    events.add('torrent-client');
    super.dispose();
  }
}

class _FailingDownloads extends DownloadRepository {
  _FailingDownloads(super.library, super.torrents, this.events);
  final List<String> events;
  bool failClose = false;
  @override
  Future<void> close() async {
    events.add('downloads');
    await super.close();
    if (failClose) throw StateError(_privateError);
  }
}

class _FailingEngine extends TorrentEngine {
  _FailingEngine(super.root, this.events);
  final List<String> events;
  @override
  Future<void> stop() async {
    events.add('engine');
    throw StateError(_privateError);
  }
}

class _FailingJackett extends JackettService {
  _FailingJackett(super.root, this.events);
  final List<String> events;
  @override
  Future<void> stop() async {
    events.add('jackett');
    throw StateError(_privateError);
  }
}

class _FailingSolver extends FlareSolverrService {
  _FailingSolver(super.root, this.events);
  final List<String> events;
  @override
  Future<void> stop() async {
    events.add('solver');
    throw StateError(_privateError);
  }
}

class _GatedBrowser implements CatalogTransport {
  _GatedBrowser(this.events);
  final List<String> events;
  final disposing = Completer<void>(), gate = Completer<void>();
  bool failDispose = false;
  int disposals = 0;
  @override
  Future<String> load(Uri uri) async => throw UnimplementedError();
  @override
  Future<void> connect(Uri uri) async {}
  @override
  Future<void> logout(Uri origin) async {}
  @override
  Future<void> dispose() async {
    ++disposals;
    events.add('browser-start');
    disposing.complete();
    await gate.future;
    events.add('browser-end');
    if (failDispose) throw StateError(_privateError);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.mumpa/windows-shutdown-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late List<String> events, diagnostics;
  late _FailingLibrary library;
  late _FailingAudio audio;
  late _RecordingTorrents torrents;
  late PlaybackController playback;
  late _FailingDownloads downloads;
  late _GatedBrowser browser;
  late DebugPrintCallback originalDebugPrint;
  AppController? app;
  WindowsPlayerService? shell;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-shutdown-');
    events = [];
    diagnostics = [];
    originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) diagnostics.add(message);
    };
    library = _FailingLibrary(root, events);
    await library.load();
    torrents = _RecordingTorrents(events);
    audio = _FailingAudio(events);
    playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: audio,
    );
    await playback.initialize(platformAudio: false);
    downloads = _FailingDownloads(library, torrents, events);
    browser = _GatedBrowser(events);
    app = null;
    shell = null;
  });

  tearDown(() async {
    if (!browser.gate.isCompleted) browser.gate.complete();
    if (audio.gate?.isCompleted == false) audio.gate!.complete();
    await shell?.close();
    messenger.setMockMethodCallHandler(channel, null);
    if (app != null) {
      await app!.shutdown();
    } else {
      await downloads.close();
      await playback.close();
      torrents.dispose();
    }
    library.dispose();
    debugPrint = originalDebugPrint;
    await root.delete(recursive: true);
  });

  AppController controller() => AppController(
    library: library,
    playback: playback,
    downloads: downloads,
    torrents: torrents,
    engine: _FailingEngine(root, events),
    jackett: _FailingJackett(root, events),
    flaresolverr: _FailingSolver(root, events),
    catalog: RuTrackerService(transport: browser),
  );

  test(
    'save and decoder errors still cancel and finish one playback close',
    () async {
      library.failSave = true;
      audio.failClose = true;
      audio.gate = Completer<void>();
      expect(audio.completion.hasListener, isTrue);
      expect(audio.failure.hasListener, isTrue);
      final first = playback.close();
      expect(playback.close(), same(first));
      await audio.closing.future;
      expect(audio.completion.hasListener, isFalse);
      expect(audio.failure.hasListener, isFalse);
      var finished = false;
      unawaited(
        first.then<void>((_) {
          finished = true;
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      audio.gate!.complete();
      await first;
      expect(events, ['save', 'audio']);
      expect(() => playback.addListener(() {}), throwsFlutterError);
      expect(diagnostics.any((line) => line.contains('save session')), isTrue);
      expect(
        diagnostics.any((line) => line.contains('decoder failed')),
        isTrue,
      );
      expect(diagnostics.join('\n'), isNot(contains(_privateError)));
      expect(diagnostics.join('\n'), isNot(contains('never-log-this')));
    },
  );

  test(
    'Windows quit awaits browser and all cleanup despite failures',
    () async {
      app = controller();
      library.failSave = library.failFlush = true;
      downloads.failClose = true;
      audio.failClose = true;
      browser.failDispose = true;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'initialize') {
          return {'smtc': true, 'tray': true, 'thumbnail': true};
        }
        return null;
      });
      shell = WindowsPlayerService(
        playback: playback,
        onQuit: app!.shutdown,
        channel: channel,
        enabled: true,
      );
      app!.windowsPlayer = shell;
      await shell!.initialize();
      final quit = shell!.requestQuit();
      expect(shell!.requestQuit(), same(quit));
      await browser.disposing.future;
      expect(calls, isNot(contains('quitReady')));
      expect(events, [
        'downloads',
        'save',
        'audio',
        'engine',
        'jackett',
        'solver',
        'browser-start',
      ]);
      browser.gate.complete();
      await quit;
      expect(calls.where((call) => call == 'quitReady'), hasLength(1));
      expect(calls, isNot(contains('quitFailed')));
      expect(events, [
        'downloads',
        'save',
        'audio',
        'engine',
        'jackett',
        'solver',
        'browser-start',
        'browser-end',
        'flush',
        'torrent-client',
      ]);
      await app!.shutdown();
      app!.dispose();
      expect(browser.disposals, 1);
      expect(events.where((stage) => stage == 'jackett'), hasLength(1));
      expect(events.where((stage) => stage == 'solver'), hasLength(1));
      expect(diagnostics.join('\n'), isNot(contains('never-log-this')));
      expect(diagnostics.join('\n'), isNot(contains('https://')));
      expect(
        diagnostics.any((line) => line.contains('catalog browser')),
        isTrue,
      );
      expect(diagnostics.any((line) => line.contains('library flush')), isTrue);
    },
  );

  test(
    'shutdown awaits a catalog disposal already started by sync dispose',
    () async {
      app = controller();
      app!.dispose();
      await browser.disposing.future;
      final shutdown = app!.shutdown();
      expect(app!.shutdown(), same(shutdown));
      var finished = false;
      unawaited(
        shutdown.then<void>((_) {
          finished = true;
        }),
      );
      await audio.closing.future;
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      expect(browser.disposals, 1);
      browser.gate.complete();
      await shutdown;
      expect(events.where((stage) => stage == 'browser-end'), hasLength(1));
      expect(events.where((stage) => stage == 'jackett'), hasLength(1));
      expect(events.where((stage) => stage == 'solver'), hasLength(1));
    },
  );
}
