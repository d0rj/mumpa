import 'logic/audio_runtime.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'data/download_repository.dart';
import 'data/library_repository.dart';
import 'data/application_profile.dart';
import 'data/jackett_service.dart';
import 'data/flaresolverr_service.dart';
import 'data/rutracker_service.dart';
import 'data/browser_catalog_transport.dart';
import 'data/torrent_service.dart';
import 'data/windows_player_service.dart';
import 'domain/models.dart';
import 'domain/music_metadata.dart';
import 'logic/app_controller.dart';
import 'logic/playback_controller.dart';
import 'ui/app_screen.dart';
import 'ui/theme.dart';
import 'ui/device_orientation.dart';

Future<AppController> createApplication({
  Directory? dataDirectory,
  bool demo = false,
  bool catalogEnabled = true,
  bool desktopIntegration = false,
  AudioBackend Function()? audioBackendFactory,
}) async {
  ApplicationProfile? profile;
  if (dataDirectory == null && Platform.isWindows) {
    final home = Platform.environment['USERPROFILE'] ?? '';
    profile = await ApplicationProfile.open(
      home: home,
      legacyRoots: await ApplicationProfile.legacyWindowsRoots(
        home,
        Directory(
          p.join((await getApplicationSupportDirectory()).path, 'Mumpa'),
        ),
      ),
    );
  }
  try {
    return await _createApplication(
      dataDirectory: dataDirectory ?? profile?.root,
      demo: demo,
      catalogEnabled: catalogEnabled,
      desktopIntegration: desktopIntegration,
      profileClose: profile?.close,
      audioBackendFactory: audioBackendFactory,
    );
  } catch (_) {
    await profile?.close();
    rethrow;
  }
}

Future<AppController> _createApplication({
  Directory? dataDirectory,
  required bool demo,
  required bool catalogEnabled,
  required bool desktopIntegration,
  Future<void> Function()? profileClose,
  AudioBackend Function()? audioBackendFactory,
}) async {
  final startupCleanup = <FutureOr<void> Function()>[];
  try {
    final root =
        dataDirectory ??
        Directory(
          p.join((await getApplicationSupportDirectory()).path, 'Mumpa'),
        );
    final library = LibraryRepository(root);
    startupCleanup.addAll([library.dispose, library.flush]);
    await library.load();
    final identified = library.tracks
        .where(
          (track) =>
              track.artist == 'Неизвестный исполнитель' &&
              inferredReleaseArtist(track.album) != null,
        )
        .map(
          (track) => track.copyWith(artist: inferredReleaseArtist(track.album)),
        )
        .toList();
    if (identified.isNotEmpty) await library.upsert(identified);
    // A stable executable identity prevents repeated Windows Firewall prompts
    // when tests use isolated library/state folders.
    final support = await getApplicationSupportDirectory();
    final runtime = Directory(
      p.join(
        Platform.isWindows
            ? ApplicationProfile.windowsRoot(
                Platform.environment['USERPROFILE'] ?? '',
              ).path
            : p.join(support.path, 'Mumpa'),
        'runtime',
      ),
    );
    final engine = TorrentEngine(
      root,
      binaryDirectory: runtime,
      networkInterface: () => library.settings['torrentInterface'] as String?,
    );
    startupCleanup.add(engine.stop);
    final torrents = TorrentService(
      sources: Directory(p.join(root.path, 'torrents')),
      endpoint: () async {
        final remote = library.settings['serverUrl'] as String? ?? '';
        return remote.isEmpty ? engine.start() : remote;
      },
    );
    startupCleanup.add(torrents.dispose);
    if (demo && library.settings['demoInitialized'] != true) {
      final tracks = <Track>[];
      for (final (i, name) in [
        '01 - First light.wav',
        '02 - Slow orbit.wav',
        '03 - After hours.wav',
      ].indexed) {
        // The .bin suffix lets Android compress these unchanged PCM WAV assets.
        // Installed demo files retain their original names and exact audio bytes.
        final asset = await rootBundle.load('assets/demo/$name.bin');
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
    final backend = (audioBackendFactory ?? NativeAudioBackend.new)();
    startupCleanup.add(backend.close);
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: backend,
    );
    startupCleanup.removeLast();
    startupCleanup.add(playback.close);
    await playback.initialize();
    final downloads = DownloadRepository(library, torrents);
    startupCleanup.add(downloads.close);
    await downloads.restore();
    final catalog = RuTrackerService(
      cacheDirectory: Directory(p.join(root.path, 'catalog')),
      baseUrl:
          library.settings['rutrackerMirror'] as String? ??
          'https://rutracker.org/',
      transport: BrowserCatalogTransport(
        Directory(p.join(root.path, 'catalog')),
      ),
    );
    startupCleanup.add(catalog.dispose);
    final controller = AppController(
      profileClose: profileClose,
      library: library,
      playback: playback,
      downloads: downloads,
      torrents: torrents,
      engine: engine,
      catalog: catalog,
      jackett: JackettService(root, binaryDirectory: runtime),
      flaresolverr: FlareSolverrService(root, binaryDirectory: runtime),
    );
    // Ownership transfers to the composed controller only after construction.
    startupCleanup
      ..clear()
      ..add(library.dispose)
      ..add(controller.shutdown);
    if (desktopIntegration && Platform.isWindows) {
      final shell = WindowsPlayerService(
        playback: playback,
        onQuit: controller.shutdown,
      );
      controller.windowsPlayer = shell;
      startupCleanup.add(shell.close);
      await shell.initialize();
    }
    if (catalogEnabled) {
      if (!controller.usesIndexer) unawaited(controller.initializeCatalog());
      unawaited(controller.initializeSources());
    }
    return controller;
  } catch (_) {
    for (final cleanup in startupCleanup.reversed) {
      try {
        await cleanup();
      } catch (_) {
        debugPrint('Mumpa startup: resource cleanup failed; continuing.');
      }
    }
    rethrow;
  }
}

List<String> _startupArguments = const [];

void main(List<String> arguments) {
  _startupArguments = arguments;
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Manrope',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
    yield LicenseEntryWithLineBreaks([
      'Mumpa',
      'TorrServer MatriX.145.2',
    ], await rootBundle.loadString('LICENSE'));
    yield const LicenseEntryWithLineBreaks(
      ['MusicBrainz / Cover Art Archive'],
      'MusicBrainz core data: CC0 1.0. Supplementary data: CC BY-NC-SA 3.0. '
      'https://musicbrainz.org/doc/About/Data_License\n\n'
      'Cover images retain the rights of their respective owners. '
      'https://musicbrainz.org/doc/Cover_Art_Archive',
    );
  });
  runApp(const PhoneOrientation(child: _Bootstrap()));
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  Future<AppController>? future;

  @override
  void initState() {
    super.initState();
    // Present a real first frame before native decoder loading or library work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          future = _startApplication();
        });
      }
    });
  }

  Future<AppController> _startApplication() async {
    await Future<void>.delayed(Duration.zero);
    initializeAudioRuntime();
    final app = await createApplication(desktopIntegration: true);
    final report = _startupArguments
        .where((argument) => argument.startsWith('--profile-report='))
        .firstOrNull;
    if (report != null) {
      try {
        final output = File(report.substring('--profile-report='.length));
        if (await output.exists()) {
          throw const FileSystemException('Файл диагностики уже существует.');
        }
        await output.writeAsString(
          jsonEncode({
            'pid': pid,
            'profile': app.library.root.path,
            'physicalProfile': await app.library.root.resolveSymbolicLinks(),
            'tracks': app.library.tracks.length,
            'favoriteTracks': app.library.favoriteTracks.length,
            'favoriteAlbums': app.library.favoriteAlbums.length,
            'favoritePlaylists': app.library.favoritePlaylists.length,
            'offlineTracks': app.library.offlineTracks.length,
          }),
          flush: true,
        );
      } catch (_) {
        await app.shutdown();
        rethrow;
      }
    }
    if (app.library.settings['checkAppUpdates'] != false) {
      unawaited(app.updates.check());
    } else {
      unawaited(app.updates.readInstalledVersion());
    }
    return app;
  }

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
                      onPressed: () => setState(() {
                        future = _startApplication();
                      }),
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
