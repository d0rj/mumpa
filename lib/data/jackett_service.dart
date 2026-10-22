import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'bounded_http.dart';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

const _jackettVersion = '0.24.2806';
const _jackettArchiveHash =
    '19c15d76c61979768c98c3e381aea5af95188b54e56d5fc1d9d0c76c9b784305';
const _jackettAsset = 'assets/jackett/Jackett.Binaries.Windows.zip';
const _runtimeFiles = [
  'JackettConsole.exe',
  'JackettConsole.dll',
  'Jackett.Common.dll',
];

typedef JackettProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

class JackettConnection {
  const JackettConnection({required this.baseUrl, required this.apiKey});
  final String baseUrl;
  final String apiKey;
  String get torznabUrl =>
      '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}'
      '/api/v2.0/indexers/all/results/torznab/api';
  String get dashboardUrl =>
      '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/UI/Dashboard';
}

Future<Uint8List> _loadJackettAsset() async {
  final asset = await rootBundle.load(_jackettAsset);
  return asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
}

Future<File> _prepareRuntime(
  String runtimePath,
  String expected,
  Future<Uint8List> Function() load,
) async {
  final cached = await Isolate.run(
    () => _installedRuntime(runtimePath, expected),
  );
  if (cached) return File(p.join(runtimePath, 'Jackett', 'JackettConsole.exe'));
  final bytes = await load();
  await Isolate.run(() => _extractRuntime(bytes, runtimePath, expected));
  return File(p.join(runtimePath, 'Jackett', 'JackettConsole.exe'));
}

bool _installedRuntime(String runtimePath, String expected) {
  try {
    final manifest =
        jsonDecode(
              File(
                p.join(runtimePath, '.mumpa-runtime.json'),
              ).readAsStringSync(),
            )
            as Map;
    if (manifest['archive'] != expected) return false;
    final hashes = manifest['files'] as Map;
    for (final name in _runtimeFiles) {
      final file = File(p.join(runtimePath, 'Jackett', name));
      if (!file.existsSync() ||
          sha256.convert(file.readAsBytesSync()).toString() != hashes[name]) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

void _extractRuntime(Uint8List bytes, String runtimePath, String expected) {
  if (sha256.convert(bytes).toString() != expected) {
    throw StateError('Не совпадает контрольная сумма пакета Jackett.');
  }
  final target = Directory(p.absolute(runtimePath));
  final parent = target.parent;
  parent.createSync(recursive: true);
  final staging = parent.createTempSync('jackett-installing-');
  try {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    for (final entry in archive) {
      final output = p.normalize(p.join(staging.path, entry.name));
      if (entry.isSymbolicLink || !p.isWithin(staging.path, output)) {
        throw const FormatException('Недопустимый путь в пакете Jackett.');
      }
      if (entry.isFile) {
        final file = File(output);
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(entry.content, flush: true);
      } else {
        Directory(output).createSync(recursive: true);
      }
    }
    final hashes = <String, String>{};
    for (final name in _runtimeFiles) {
      hashes[name] = sha256
          .convert(
            File(p.join(staging.path, 'Jackett', name)).readAsBytesSync(),
          )
          .toString();
    }
    File(p.join(staging.path, '.mumpa-runtime.json')).writeAsStringSync(
      jsonEncode({'archive': expected, 'files': hashes}),
      flush: true,
    );
    // Only this versioned managed installation is replaced. Profile state lives
    // elsewhere; validate the resolved path before recursive cleanup on Windows.
    if (!p.isWithin(parent.path, target.path)) {
      throw StateError('Недопустимый каталог Jackett.');
    }
    if (target.existsSync()) target.deleteSync(recursive: true);
    staging.renameSync(target.path);
  } finally {
    if (staging.existsSync() && p.isWithin(parent.path, staging.path)) {
      staging.deleteSync(recursive: true);
    }
  }
}

/// A private, application-owned Windows Jackett instance. External Jackett
/// connections can still use [isRuTrackerConfigured] without spawning a process.
class JackettService {
  JackettService(this.root, {this.binaryDirectory})
    : _assetLoader = _loadJackettAsset,
      _archiveHash = _jackettArchiveHash,
      _startProcess = Process.start,
      _clientFactory = http.Client.new,
      _legacyProfile = Platform.environment['APPDATA'] == null
          ? null
          : Directory(p.join(Platform.environment['APPDATA']!, 'Jackett')),
      _startupTimeout = const Duration(seconds: 60),
      _testing = false;

  @visibleForTesting
  JackettService.testing(
    this.root, {
    this.binaryDirectory,
    required this._assetLoader,
    required this._archiveHash,
    required this._startProcess,
    required this._clientFactory,
    this._legacyProfile,
    this._startupTimeout = const Duration(seconds: 60),
  }) : _testing = true;

  final Directory root;
  final Directory? binaryDirectory;
  final Future<Uint8List> Function() _assetLoader;
  final String _archiveHash;
  final JackettProcessStarter _startProcess;
  final http.Client Function() _clientFactory;
  final Directory? _legacyProfile;
  final Duration _startupTimeout;
  final bool _testing;
  _JackettProcess? _process;
  Future<JackettConnection>? _starting;
  Future<void>? _stopping;
  int _generation = 0;

  Future<JackettConnection> start() {
    final stopping = _stopping;
    if (stopping != null) return stopping.then((_) => start());
    return _starting ??= _start(++_generation).catchError((Object e) {
      _starting = null;
      throw e;
    });
  }

  void _checkActive(int generation) {
    if (generation != _generation) {
      throw StateError('Запуск Jackett отменён.');
    }
  }

  Future<JackettConnection> _start(int generation) async {
    if (!Platform.isWindows && !_testing) {
      throw UnsupportedError(
        'Встроенный Jackett доступен на Windows. '
        'На телефоне подключите Jackett с компьютера или сервера.',
      );
    }
    final state = Directory(p.join(root.path, 'jackett'));
    final legacy = _legacyProfile;
    // Jackett's Windows migration unconditionally considers Roaming/Jackett,
    // including custom DataFolder launches. Never let it migrate another profile.
    if (legacy != null &&
        !p.equals(p.absolute(legacy.path), p.absolute(state.path)) &&
        await legacy.exists()) {
      throw StateError(
        'Найден существующий профиль Jackett в ${legacy.path}. '
        'Подключите этот Jackett в настройках через его Torznab URL и API key.',
      );
    }
    await state.create(recursive: true);
    final binaries = binaryDirectory ?? Directory(p.join(root.path, 'runtime'));
    final executable = await _prepareRuntime(
      p.join(binaries.path, 'Jackett-$_jackettVersion'),
      _archiveHash,
      _assetLoader,
    );
    _checkActive(generation);
    final configFile = File(p.join(state.path, 'ServerConfig.json'));
    final config = await configFile.exists()
        ? Map<String, dynamic>.from(
            jsonDecode(await configFile.readAsString()) as Map,
          )
        : <String, dynamic>{};
    final configuredPort = config['Port'];
    ServerSocket socket;
    try {
      socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        configuredPort is int && configuredPort > 1024 && configuredPort < 65536
            ? configuredPort
            : 0,
      );
    } on SocketException {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    final port = socket.port;
    _JackettProcess? process;
    final client = _clientFactory();
    try {
      final existingKey = config['APIKey'];
      final apiKey = existingKey is String && existingKey.trim().isNotEmpty
          ? existingKey
          : List.generate(
              16,
              (_) => Random.secure().nextInt(256),
            ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
      config.addAll({
        'Port': port,
        'LocalBindAddress': '127.0.0.1',
        'AllowExternal': false,
        'UpdateDisabled': true,
        'APIKey': apiKey,
      });
      // Prewrite the exact CLI values: Jackett's Windows CLI port/public override
      // otherwise requests administrator rights and reserves machine-wide URLs.
      await configFile.writeAsString(jsonEncode(config), flush: true);
      _checkActive(generation);
      await socket.close();
      final native = await _startProcess(executable.path, [
        '--DataFolder',
        state.path,
        '--Port',
        '$port',
        '--ListenPrivate',
        '--NoUpdates',
        '--NoRestart',
      ], workingDirectory: executable.parent.path);
      final connection = JackettConnection(
        baseUrl:
            'http://127.0.0.1:$port'
            '${(config['BasePathOverride'] as String? ?? '').replaceFirst(RegExp(r'/+$'), '')}',
        apiKey: apiKey,
      );
      process = _JackettProcess(native, state, connection);
      _process = process;
      final running = process;
      unawaited(
        running.exited.then((_) {
          if (running.ready && identical(_process, running)) {
            _process = null;
            _starting = null;
          }
        }),
      );
      _checkActive(generation);
      await _waitReady(process, client, generation);
      process.ready = true;
      return connection;
    } catch (_) {
      if (process != null) {
        await process.stop();
        if (identical(_process, process)) _process = null;
      }
      rethrow;
    } finally {
      await socket.close();
      client.close();
    }
  }

  Future<void> _waitReady(
    _JackettProcess process,
    http.Client client,
    int generation,
  ) async {
    final connection = process.connection;
    final uri = Uri.parse(
      connection.torznabUrl,
    ).replace(queryParameters: {'t': 'caps', 'apikey': connection.apiKey});
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < _startupTimeout) {
      _checkActive(generation);
      if (process.code != null) throw await process.failure();
      try {
        final response = await Future.any([
          getBounded(client, uri, timeout: const Duration(seconds: 2)),
          process.exited.then<http.Response>(
            (_) async => throw await process.failure(),
          ),
        ]);
        _checkActive(generation);
        if (process.code != null) throw await process.failure();
        if (response.statusCode == 200 &&
            XmlDocument.parse(response.body).rootElement.name.local == 'caps') {
          return;
        }
      } on _JackettExited {
        rethrow;
      } catch (_) {
        _checkActive(generation);
      }
      await Future.any([
        Future<void>.delayed(const Duration(milliseconds: 200)),
        process.exited.then<void>((_) async => throw await process.failure()),
      ]);
    }
    throw StateError(
      'Jackett не ответил. Проверьте ${process.logPath} и '
      '${p.join(root.path, 'jackett', 'log.txt')}.',
    );
  }

  /// Torznab's authenticated indexer inventory works without UI cookies and
  /// continues working if a dashboard password is later enabled.
  Future<bool> isRuTrackerConfigured([JackettConnection? connection]) async {
    connection ??= await start();
    final client = _clientFactory();
    try {
      final uri = Uri.parse(connection.torznabUrl).replace(
        queryParameters: {
          't': 'indexers',
          'configured': 'true',
          'apikey': connection.apiKey,
        },
      );
      final response = await getBounded(
        client,
        uri,
        timeout: const Duration(seconds: 10),
      );
      if (response.statusCode != 200) {
        throw HttpException('Jackett не отвечает (${response.statusCode}).');
      }
      final document = XmlDocument.parse(response.body);
      if (document.rootElement.name.local != 'indexers') {
        throw const FormatException(
          'Не удалось получить индексаторы Jackett. Проверьте API key.',
        );
      }
      return document
          .findAllElements('indexer')
          .any(
            (indexer) =>
                indexer.getAttribute('id') == 'rutracker' &&
                indexer.getAttribute('configured')?.toLowerCase() == 'true',
          );
    } on http.ClientException {
      // ClientException embeds its request URI, which contains the API key.
      throw const HttpException('Не удалось подключиться к Jackett.');
    } on TimeoutException {
      throw const HttpException('Jackett не ответил за 10 секунд.');
    } finally {
      client.close();
    }
  }

  /// Updates only the solver settings on our private dashboard. Jackett reloads
  /// its web host in the same process; tracker/account configuration is retained.
  Future<void> configureFlareSolverr(
    JackettConnection connection,
    String solverUrl,
  ) async {
    final solver = Uri.tryParse(solverUrl);
    if (solver == null ||
        solver.scheme != 'http' ||
        solver.host != '127.0.0.1' ||
        !solver.hasPort) {
      throw const FormatException(
        'Некорректный адрес локального FlareSolverr.',
      );
    }
    final client = _clientFactory();
    try {
      final login = http.Request(
        'GET',
        Uri.parse('${connection.baseUrl}/UI/Login?cookiesChecked=1'),
      )..followRedirects = false;
      final response = await client
          .send(login)
          .timeout(const Duration(seconds: 8));
      await response.stream.listen((_) {}).cancel();
      final cookie = RegExp(
        r'Jackett=[^;,\s]+',
      ).firstMatch(response.headers['set-cookie'] ?? '')?.group(0);
      if (cookie == null) {
        throw const HttpException(
          'В Jackett включён пароль панели. Укажи адрес FlareSolverr в настройках Jackett вручную.',
        );
      }
      final uri = Uri.parse('${connection.baseUrl}/api/v2.0/server/config');
      final headers = {'cookie': cookie, 'content-type': 'application/json'};
      final current = await getBounded(
        client,
        uri,
        headers: headers,
        timeout: const Duration(seconds: 8),
      );
      if (current.statusCode != 200) {
        throw const HttpException('Не удалось прочитать настройки Jackett.');
      }
      final config = Map<String, dynamic>.from(jsonDecode(current.body) as Map);
      // Include the same settings as the dashboard, preserving proxy and cache
      // fields. API keys/passwords returned by GET are never sent back or logged.
      const fields = [
        'port',
        'external',
        'local_bind_address',
        'cors',
        'updatedisabled',
        'prerelease',
        'blackholedir',
        'logging',
        'basepathoverride',
        'baseurloverride',
        'cache_enabled',
        'cache_ttl',
        'cache_max_results_per_indexer',
        'omdbkey',
        'omdburl',
        'proxy_type',
        'proxy_url',
        'proxy_port',
        'proxy_username',
        'proxy_password',
      ];
      final updated = <String, dynamic>{
        for (final key in fields) key: config[key],
        'flaresolverrurl': solverUrl,
        'flaresolverr_maxtimeout': 60000,
      };
      if (config['flaresolverrurl'] == solverUrl &&
          config['flaresolverr_maxtimeout'] == 60000) {
        return;
      }
      final saved = await postBounded(
        client,
        uri,
        headers: headers,
        body: jsonEncode(updated),
        timeout: const Duration(seconds: 15),
      );
      if (saved.statusCode != 200) {
        throw const HttpException(
          'Не удалось настроить FlareSolverr в Jackett.',
        );
      }
    } on http.ClientException {
      throw const HttpException('Не удалось подключиться к панели Jackett.');
    } on TimeoutException {
      throw const HttpException('Панель Jackett не ответила вовремя.');
    } finally {
      client.close();
    }
  }

  Future<void> stop() => _stopping ??= _stop().whenComplete(() {
    _stopping = null;
  });

  Future<void> _stop() async {
    ++_generation;
    final starting = _starting;
    _starting = null;
    final process = _process;
    _process = null;
    if (process != null) {
      if (process.ready && process.code == null) {
        final client = _clientFactory();
        try {
          await client
              .post(
                Uri.parse(
                  '${process.connection.baseUrl}/api/v2.0/server/shutdown',
                ).replace(
                  queryParameters: {'apikey': process.connection.apiKey},
                ),
              )
              .timeout(const Duration(seconds: 1));
          await process.exited.timeout(const Duration(seconds: 2));
        } catch (_) {
          // A stopped/unresponsive host is cleaned up by the process fallback.
        } finally {
          client.close();
        }
      }
      await process.stop();
    }
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }
  }
}

class _JackettExited extends StateError {
  _JackettExited(super.message);
}

class _JackettProcess {
  _JackettProcess(this.process, Directory state, this.connection)
    : logPath = p.join(state.path, 'startup.log'),
      _log = File(
        p.join(state.path, 'startup.log'),
      ).openWrite(mode: FileMode.append) {
    _log.writeln(
      '\n${DateTime.now().toIso8601String()} Jackett $_jackettVersion '
      'pid=${process.pid} url=${connection.baseUrl}',
    );
    unawaited(_log.done.catchError((Object _) {}));
    final streams = [
      _capture(process.stdout, 'stdout'),
      _capture(process.stderr, 'stderr'),
    ];
    exited = process.exitCode.then((value) {
      code = value;
      return value;
    });
    _finished = exited.then((value) async {
      try {
        await Future.wait(streams);
        _log.writeln('exit code=$value');
        await _log.flush();
      } finally {
        await _log.close();
      }
    });
    unawaited(_finished.catchError((Object _) {}));
  }

  final Process process;
  final JackettConnection connection;
  final String logPath;
  final IOSink _log;
  late final Future<int> exited;
  late final Future<void> _finished;
  int? code;
  bool ready = false;
  String _tail = '';

  Future<void> _capture(Stream<List<int>> stream, String name) => stream
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .forEach((line) => _record(name, line))
      .catchError((Object e) => _record(name, 'stream error: $e'));

  void _record(String name, String line) {
    // Line buffering also removes keys split across separate stdout chunks.
    final safe = line.replaceAll(
      RegExp(RegExp.escape(connection.apiKey), caseSensitive: false),
      '[REDACTED]',
    );
    _tail += '$safe\n';
    if (_tail.length > 4096) _tail = _tail.substring(_tail.length - 4096);
    try {
      _log.writeln('[$name] $safe');
    } catch (_) {}
  }

  Future<_JackettExited> failure() async {
    try {
      await _finished;
    } catch (_) {}
    return _JackettExited(
      'Jackett завершился (код $code). '
      'Журнал: $logPath.${_tail.trim().isEmpty ? '' : '\n${_tail.trim()}'}',
    );
  }

  Future<void> stop() async {
    if (code == null) process.kill();
    try {
      await exited.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await exited.timeout(const Duration(seconds: 2));
    }
    try {
      await _finished;
    } catch (_) {}
  }
}
