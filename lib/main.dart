import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'data/download_repository.dart';
import 'data/library_repository.dart';
import 'data/jackett_service.dart';
import 'data/flaresolverr_service.dart';
import 'data/rutracker_service.dart';
import 'data/browser_catalog_transport.dart';
import 'data/torrent_service.dart';
import 'domain/models.dart';
import 'logic/app_controller.dart';
import 'logic/playback_controller.dart';
import 'ui/app_screen.dart';
import 'ui/theme.dart';

Future<AppController> createApplication({
  Directory? dataDirectory,
  bool demo = false,
  bool catalogEnabled = true,
}) async {
  final root =
      dataDirectory ??
      Directory(p.join((await getApplicationSupportDirectory()).path, 'Mumpa'));
  final library = LibraryRepository(root);
  await library.load();
  // A stable executable identity prevents repeated Windows Firewall prompts
  // when tests use isolated library/state folders.
  final support = await getApplicationSupportDirectory();
  final engine = TorrentEngine(
    root,
    binaryDirectory: Directory(p.join(support.path, 'Mumpa', 'runtime')),
  );
  final torrents = TorrentService(
    sources: Directory(p.join(root.path, 'torrents')),
    endpoint: () async {
      final remote = library.settings['serverUrl'] as String? ?? '';
      return remote.isEmpty ? engine.start() : remote;
    },
  );
  if (demo && library.settings['demoInitialized'] != true) {
    final tracks = <Track>[];
    for (final (i, name) in [
      '01 - First light.wav',
      '02 - Slow orbit.wav',
      '03 - After hours.wav',
    ].indexed) {
      final asset = await rootBundle.load('assets/demo/$name');
      final file = File(p.join(root.path, 'demo', name));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      );
      tracks.add(
        Track(
          id: 'demo-$i',
          title: ['First light', 'Slow orbit', 'After hours'][i],
          artist: 'Mumpa Sessions',
          album: 'First light · Демо',
          source: TrackSource.demo,
          localPath: file.path,
          bytes: asset.lengthInBytes,
          durationMs: 24000,
          number: i + 1,
          year: 2026,
        ),
      );
    }
    await library.upsert(tracks);
    await library.setSetting('demoInitialized', true);
  }
  final playback = PlaybackController(
    library: library,
    torrents: torrents,
    backend: NativeAudioBackend(),
  );
  await playback.initialize();
  final downloads = DownloadRepository(library, torrents);
  await downloads.restore();
  final catalog = RuTrackerService(
    cacheDirectory: Directory(p.join(root.path, 'catalog')),
    baseUrl:
        library.settings['rutrackerMirror'] as String? ??
        'https://rutracker.org/',
    transport: BrowserCatalogTransport(Directory(p.join(root.path, 'catalog'))),
  );
  final controller = AppController(
    library: library,
    playback: playback,
    downloads: downloads,
    torrents: torrents,
    engine: engine,
    catalog: catalog,
    jackett: JackettService(
      root,
      binaryDirectory: Directory(p.join(support.path, 'Mumpa', 'runtime')),
    ),
    flaresolverr: FlareSolverrService(
      root,
      binaryDirectory: Directory(p.join(support.path, 'Mumpa', 'runtime')),
    ),
  );
  if (catalogEnabled) {
    if (!controller.usesIndexer) unawaited(controller.initializeCatalog());
    unawaited(controller.initializeSources());
  }
  return controller;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Manrope',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
    yield LicenseEntryWithLineBreaks([
      'Mumpa',
      'TorrServer MatriX.145.2',
    ], await rootBundle.loadString('LICENSE'));
  });
  runApp(const _Bootstrap());
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late Future<AppController> future = createApplication();
  @override
  Widget build(BuildContext context) => FutureBuilder<AppController>(
    future: future,
    builder: (context, state) {
      if (state.hasData) return MumpaApp(controller: state.data!);
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: mumpaTheme(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.graphic_eq_rounded, color: accent, size: 56),
                  const SizedBox(height: 16),
                  const Text(
                    'mumpa',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.5,
                    ),
                  ),
                  const SizedBox(height: 26),
                  if (state.hasError) ...[
                    Text(
                      'Не удалось запустить приложение:\n${state.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () =>
                          setState(() => future = createApplication()),
                      child: const Text('Попробовать снова'),
                    ),
                  ] else
                    const SizedBox(
                      width: 160,
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
