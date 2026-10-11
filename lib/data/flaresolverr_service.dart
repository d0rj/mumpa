import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

const _version = '3.5.2';
const _archiveHash =
    'de288f2d563764b648b3ce4ed5bc5fad873de49300f2991ba4f13d9a73b9bb6d';
const _asset = 'assets/flaresolverr/flaresolverr_windows_x64_runtime.zip';
const _criticalFiles = [
  'flaresolverr/flaresolverr.exe',
  'flaresolverr/_internal/python311.dll',
  'flaresolverr/_internal/chrome/chrome.exe',
  'flaresolverr/_internal/chrome/chrome.dll',
];

typedef FlareSolverrLauncher =
    Future<Process> Function(
      String executable,
      Map<String, String> environment,
      String workingDirectory,
    );

/// Closing a guard terminates only the managed process and its descendants.
abstract interface class FlareSolverrProcessGuard {
  void close();
}

class FlareSolverrProbeResult {
  const FlareSolverrProbeResult({
    required this.success,
    required this.challengeSolved,
    this.siteStatus,
  });
  final bool success;
  final bool challengeSolved;
  final int? siteStatus;
}

Future<Process> _launch(
  String executable,
  Map<String, String> environment,
  String workingDirectory,
) => Process.start(
  executable,
  const [],
  environment: environment,
  workingDirectory: workingDirectory,
);

Future<String> _fileHash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<String> _prepareIsolated(
  String archivePath,
  String directory,
  String expected,
) => Isolate.run(() => _prepare(archivePath, directory, expected));

Future<bool> _installed(String directory, String expected) async {
  try {
    final manifest =
        jsonDecode(
              await File(
                p.join(directory, '.mumpa-runtime.json'),
              ).readAsString(),
            )
            as Map;
    if (manifest['archive'] != expected) return false;
    final hashes = manifest['files'] as Map;
    for (final name in _criticalFiles) {
      final file = File(p.join(directory, name));
      if (!await file.exists() || await _fileHash(file) != hashes[name]) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<String> _prepare(
  String archivePath,
  String directory,
  String expected,
) async {
  if (await _installed(directory, expected)) {
    return p.join(directory, 'flaresolverr', 'flaresolverr.exe');
  }
  if (await _fileHash(File(archivePath)) != expected) {
    throw StateError('Не совпадает контрольная сумма пакета FlareSolverr.');
  }
  final target = Directory(p.absolute(directory));
  final parent = target.parent;
  await parent.create(recursive: true);
  final staging = await parent.createTemp('flaresolverr-installing-');
  final input = InputFileStream(archivePath);
  try {
    // Decode file-backed streams and inflate directly into file streams. Neither
    // the runtime ZIP nor Chromium's large DLL is copied onto the UI isolate.
    final archive = ZipDecoder().decodeStream(input);
    for (final entry in archive) {
      final outputPath = p.normalize(p.join(staging.path, entry.name));
      if (entry.isSymbolicLink || !p.isWithin(staging.path, outputPath)) {
        throw const FormatException('Недопустимый путь в пакете FlareSolverr.');
      }
      if (entry.isDirectory) {
        Directory(outputPath).createSync(recursive: true);
      } else {
        File(outputPath).parent.createSync(recursive: true);
        final output = OutputFileStream(outputPath);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
      }
    }
    final hashes = <String, String>{};
    for (final name in _criticalFiles) {
      hashes[name] = await _fileHash(File(p.join(staging.path, name)));
    }
    await File(p.join(staging.path, '.mumpa-runtime.json')).writeAsString(
      jsonEncode({'archive': expected, 'files': hashes}),
      flush: true,
    );
    if (!p.isWithin(parent.path, target.path)) {
      throw StateError('Недопустимый каталог FlareSolverr.');
    }
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
    return p.join(target.path, 'flaresolverr', 'flaresolverr.exe');
  } finally {
    input.closeSync();
    if (await staging.exists() && p.isWithin(parent.path, staging.path)) {
      await staging.delete(recursive: true);
    }
  }
}

/// Optional Windows challenge helper. Construction never starts a browser.
class FlareSolverrService {
  @visibleForTesting
  static FlareSolverrProcessGuard guardProcess(int pid) =>
      _WindowsJob.attach(pid);

  FlareSolverrService(this.root, {this.binaryDirectory})
    : _bundledArchive = null,
      _expectedHash = _archiveHash,
      _launcher = _launch,
      _guardFactory = _WindowsJob.attach,
      _clientFactory = http.Client.new,
      _startupTimeout = const Duration(seconds: 75),
      _testing = false;

  @visibleForTesting
  FlareSolverrService.testing(
    this.root, {
    this.binaryDirectory,
    required File this._bundledArchive,
    required this._expectedHash,
    required this._launcher,
    required this._guardFactory,
    required this._clientFactory,
    this._startupTimeout = const Duration(seconds: 75),
  }) : _testing = true;

  final Directory root;
  final Directory? binaryDirectory;
  final File? _bundledArchive;
  final String _expectedHash;
  final FlareSolverrLauncher _launcher;
  final FlareSolverrProcessGuard Function(int) _guardFactory;
  final http.Client Function() _clientFactory;
  final Duration _startupTimeout;
  final bool _testing;
  _SolverProcess? _process;
  Future<String>? _starting;
  Future<void>? _stopping;
  int _generation = 0;

  Future<bool> isEnabled() =>
      File(p.join(root.path, 'flaresolverr', 'enabled')).exists();

  Future<String> enable() async {
    final marker = File(p.join(root.path, 'flaresolverr', 'enabled'));
    final base = await start();
    await marker.parent.create(recursive: true);
    await marker.writeAsString('$_version\n', flush: true);
    return base;
  }

  Future<void> disable() async {
    final marker = File(p.join(root.path, 'flaresolverr', 'enabled'));
    if (await marker.exists()) await marker.delete();
    await stop();
  }

  Future<String> start() {
    final stopping = _stopping;
    if (stopping != null) return stopping.then((_) => start());
    return _starting ??= _start(++_generation).catchError((Object e) {
      _starting = null;
      throw e;
    });
  }

  void _checkActive(int generation) {
    if (generation != _generation) {
      throw StateError('Запуск FlareSolverr отменён.');
    }
  }

  Future<String> _archivePath() async {
    if (_bundledArchive != null) return _bundledArchive.path;
    final installed = p.join(
      p.dirname(Platform.resolvedExecutable),
      'data',
      'flutter_assets',
      _asset,
    );
    if (await File(installed).exists()) return installed;
    if (kDebugMode && await File(_asset).exists()) return p.absolute(_asset);
    throw StateError(
      'Пакет FlareSolverr отсутствует. Переустановите приложение.',
    );
  }

  Future<String> _start(int generation) async {
    if (!Platform.isWindows && !_testing) {
      throw UnsupportedError(
        'Встроенный FlareSolverr доступен только на Windows.',
      );
    }
    final binaries = binaryDirectory ?? Directory(p.join(root.path, 'runtime'));
    final directory = p.join(binaries.path, 'FlareSolverr-$_version');
    final archivePath = await _archivePath();
    final expected = _expectedHash;
    final executable = await _prepareIsolated(archivePath, directory, expected);
    _checkActive(generation);
    final state = Directory(p.join(root.path, 'flaresolverr'));
    for (final name in ['tmp', 'home', 'appdata', 'local']) {
      await Directory(p.join(state.path, name)).create(recursive: true);
    }
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    _SolverProcess? process;
    Process? native;
    final client = _clientFactory();
    try {
      final environment = <String, String>{
        'HOST': '127.0.0.1',
        'PORT': '$port',
        'HEADLESS': 'true',
        'LOG_LEVEL': 'error',
        'LOG_HTML': 'false',
        'LOG_FILE': '',
        'PROMETHEUS_ENABLED': 'false',
        'TEMP': p.join(state.path, 'tmp'),
        'TMP': p.join(state.path, 'tmp'),
        'USERPROFILE': p.join(state.path, 'home'),
        'APPDATA': p.join(state.path, 'appdata'),
        'LOCALAPPDATA': p.join(state.path, 'local'),
      };
      _checkActive(generation);
      await socket.close();
      native = await _launcher(executable, environment, p.dirname(executable));
      final guard = _guardFactory(native.pid);
      process = _SolverProcess(native, guard);
      _process = process;
      final running = process;
      unawaited(
        running.exited.then((_) {
          running.guard.close();
          if (running.ready && identical(_process, running)) {
            _process = null;
            _starting = null;
          }
        }),
      );
      final base = 'http://127.0.0.1:$port';
      final elapsed = Stopwatch()..start();
      while (elapsed.elapsed < _startupTimeout) {
        _checkActive(generation);
        if (process.code != null) throw _SolverExited(process.code!);
        try {
          final remaining = _startupTimeout - elapsed.elapsed;
          final timeout = remaining < const Duration(seconds: 2)
              ? remaining
              : const Duration(seconds: 2);
          final response = await Future.any([
            client.get(Uri.parse('$base/health')).timeout(timeout),
            process.exited.then<http.Response>(
              (code) => throw _SolverExited(code),
            ),
          ]);
          _checkActive(generation);
          if (process.code != null) throw _SolverExited(process.code!);
          if (response.statusCode == 200 &&
              (jsonDecode(response.body) as Map)['status'] == 'ok') {
            process.ready = true;
            return base;
          }
        } on _SolverExited {
          rethrow;
        } catch (_) {
          _checkActive(generation);
        }
        await Future.any([
          Future<void>.delayed(const Duration(milliseconds: 200)),
          process.exited.then<void>((code) => throw _SolverExited(code)),
        ]);
      }
      throw StateError(
        'FlareSolverr не запустился за ${_startupTimeout.inSeconds} с. '
        'Проверьте доступ к загрузке ChromeDriver и свободное место.',
      );
    } catch (_) {
      if (process != null) {
        await process.stop();
        if (identical(_process, process)) _process = null;
      } else if (native != null) {
        native.kill();
        await native.exitCode.timeout(const Duration(seconds: 5));
      }
      rethrow;
    } finally {
      await socket.close();
      client.close();
    }
  }

  /// The diagnostic result deliberately excludes HTML, cookies and solver text.
  /// Without a session, upstream closes its request browser in a finally block.
  Future<FlareSolverrProbeResult> probe(
    Uri url, {
    Duration maxTimeout = const Duration(seconds: 45),
  }) async {
    if (!{'https', 'http'}.contains(url.scheme) || url.userInfo.isNotEmpty) {
      throw const FormatException(
        'Для проверки нужен HTTP/HTTPS URL без учётных данных.',
      );
    }
    final base = await start();
    final client = _clientFactory();
    try {
      final response = await client
          .post(
            Uri.parse('$base/v1'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'cmd': 'request.get',
              'url': url.toString(),
              'maxTimeout': maxTimeout.inMilliseconds,
            }),
          )
          .timeout(maxTimeout + const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw const HttpException('FlareSolverr не выполнил проверку.');
      }
      final result = jsonDecode(response.body) as Map;
      final solution = result['solution'];
      final siteStatus = solution is Map ? solution['status'] : null;
      return FlareSolverrProbeResult(
        success: result['status'] == 'ok',
        challengeSolved: result['message'] == 'Challenge solved!',
        siteStatus: siteStatus is int ? siteStatus : null,
      );
    } on TimeoutException {
      throw const HttpException('Истекло время проверки FlareSolverr.');
    } on http.ClientException {
      throw const HttpException('Не удалось подключиться к FlareSolverr.');
    } on FormatException {
      throw const HttpException('FlareSolverr вернул некорректный ответ.');
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
    await process?.stop();
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }
  }
}

class _SolverExited extends StateError {
  _SolverExited(int code)
    : super('FlareSolverr завершился при запуске (код $code).');
}

class _SolverProcess {
  _SolverProcess(this.process, this.guard) {
    // Never persist or relay third-party diagnostics: exceptions can contain
    // request URLs, credential fields, cookies or the returned HTML.
    _outputs = Future.wait([
      process.stdout.drain<void>().catchError((Object _) {}),
      process.stderr.drain<void>().catchError((Object _) {}),
    ]);
    exited = process.exitCode.then((value) {
      code = value;
      return value;
    });
  }
  final Process process;
  final FlareSolverrProcessGuard guard;
  late final Future<int> exited;
  late final Future<List<void>> _outputs;
  int? code;
  bool ready = false;

  Future<void> stop() async {
    guard.close();
    try {
      await exited.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      await exited.timeout(const Duration(seconds: 2));
    }
    await _outputs;
  }
}

class _WindowsJob implements FlareSolverrProcessGuard {
  _WindowsJob(this._handle, this._close);
  Pointer<Void> _handle;
  final int Function(Pointer<Void>) _close;

  static FlareSolverrProcessGuard attach(int pid) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final create = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>)
        >('CreateJobObjectW');
    final close = kernel
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('CloseHandle');
    final alloc = kernel
        .lookupFunction<
          Pointer<Void> Function(Uint32, IntPtr),
          Pointer<Void> Function(int, int)
        >('LocalAlloc');
    final free = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    final set = kernel
        .lookupFunction<
          Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int, Pointer<Void>, int)
        >('SetInformationJobObject');
    final open = kernel
        .lookupFunction<
          Pointer<Void> Function(Uint32, Int32, Uint32),
          Pointer<Void> Function(int, int, int)
        >('OpenProcess');
    final assign = kernel
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>)
        >('AssignProcessToJobObject');
    final job = create(nullptr, nullptr);
    if (job == nullptr) {
      throw StateError('Не удалось изолировать процесс FlareSolverr.');
    }
    final limits = alloc(
      0x40,
      144,
    ); // Zeroed x64 JOBOBJECT_EXTENDED_LIMIT_INFORMATION.
    Pointer<Void> process = nullptr;
    try {
      if (limits == nullptr) {
        throw StateError('Не хватает памяти для запуска FlareSolverr.');
      }
      (limits.cast<Uint8>() + 16).cast<Uint32>().value = 0x2000;
      process = open(0x0101, 0, pid); // PROCESS_SET_QUOTA | PROCESS_TERMINATE.
      if (set(job, 9, limits, 144) == 0 ||
          process == nullptr ||
          assign(job, process) == 0) {
        throw StateError('Не удалось изолировать процесс FlareSolverr.');
      }
      return _WindowsJob(job, close);
    } catch (_) {
      close(job);
      rethrow;
    } finally {
      if (limits != nullptr) free(limits);
      if (process != nullptr) close(process);
    }
  }

  @override
  void close() {
    final handle = _handle;
    _handle = nullptr;
    if (handle != nullptr) _close(handle);
  }
}
