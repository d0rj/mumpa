import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

const _releaseRoot = 'https://github.com/d0rj/mumpa/releases';
const _updateChannel = MethodChannel('app.mumpa/updates');

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.fileName,
    required this.bytes,
    required this.sha256,
    this.androidSigning,
    this.privateAssetPath,
  });
  final String version, fileName, sha256;
  final int bytes;
  final String? androidSigning;
  final String? privateAssetPath;
  Uri get url => Uri.parse(
    '$_releaseRoot/download/v${version.split('+').first}/$fileName',
  );
}

/// Only stable, published releases with matching package hashes are offered.
/// All storage is outside the program directory, including the update helper.
class AppUpdateService extends ChangeNotifier {
  AppUpdateService(
    this.directory, {
    http.Client Function()? clientFactory,
    Future<String> Function()? installedVersion,
    Future<String> Function()? target,
    Future<http.StreamedResponse> Function(String)? privateApi,
    bool? allowPrivateFallback,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _installedVersion = installedVersion ?? _nativeVersion,
       _target = target ?? _nativeTarget,
       _privateApi = privateApi,
       _allowPrivateFallback =
           allowPrivateFallback ??
           (privateApi != null || clientFactory == null);

  final Directory directory;
  final http.Client Function() _clientFactory;
  final Future<String> Function() _installedVersion, _target;
  final Future<http.StreamedResponse> Function(String)? _privateApi;
  final bool _allowPrivateFallback;
  Process? _githubProcess;
  String currentVersion = '', status = 'Проверь наличие новой версии.';
  String? error;
  AppUpdate? available;
  File? downloaded;
  bool busy = false, _disposed = false, _cancelled = false;
  int received = 0;
  http.Client? _client;
  double? get progress =>
      available == null || received == 0 ? null : received / available!.bytes;

  static Future<String> _nativeVersion() async {
    final info = await PackageInfo.fromPlatform();
    return '${info.version}+${info.buildNumber}';
  }

  Future<void> readInstalledVersion() async {
    try {
      currentVersion = await _installedVersion();
      _changed();
    } catch (_) {
      // A version lookup must not prevent starting the player.
    }
  }

  static Future<String> _nativeTarget() async {
    if (Platform.isWindows) return 'windows-x64.zip';
    if (Platform.isAndroid) {
      final abis = await _updateChannel.invokeListMethod<String>('abis') ?? [];
      for (final abi in abis) {
        final target = switch (abi) {
          'arm64-v8a' => 'arm64',
          'armeabi-v7a' => 'armv7',
          'x86_64' => 'x86_64',
          _ => null,
        };
        if (target != null) return 'android-$target.apk';
      }
    }
    throw const FormatException('Для этого устройства нет пакета обновления.');
  }

  static int compareVersions(String a, String b) {
    List<int> parse(String value) {
      if (!RegExp(r'^\d+\.\d+\.\d+(?:\+\d+)?$').hasMatch(value)) {
        throw const FormatException('Некорректная версия выпуска.');
      }
      final parts = value.split('+');
      return [
        ...parts.first.split('.').map(int.parse),
        parts.length == 2 ? int.parse(parts.last) : 0,
      ];
    }

    final left = parse(a), right = parse(b);
    for (var i = 0; i < left.length; i++) {
      final order = left[i].compareTo(right[i]);
      if (order != 0) return order;
    }
    return 0;
  }

  Future<Object?> _json(Uri uri) async {
    final response = await _client!
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 25));
    return _readJson(response);
  }

  Future<Object?> _readJson(http.StreamedResponse response) async {
    if (response.statusCode != 200) {
      if (response.statusCode == 404) {
        throw const FormatException('Опубликованный выпуск пока недоступен.');
      }
      throw HttpException(
        'Сервер обновлений ответил HTTP ${response.statusCode}.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 25),
    )) {
      if (bytes.length + chunk.length > 256 * 1024) {
        throw const FormatException(
          'Слишком большой файл сведений об обновлении.',
        );
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes).replaceFirst('\uFEFF', ''));
  }

  Future<http.StreamedResponse> _githubApi(String path) async {
    if (_privateApi != null) return _privateApi(path);
    if (!Platform.isWindows) {
      throw const FormatException(
        'Приватный выпуск требует авторизации GitHub. На Windows используется gh auth login.',
      );
    }
    final winget = p.join(
      Platform.environment['LOCALAPPDATA'] ?? '',
      'Microsoft',
      'WinGet',
      'Links',
      'gh.exe',
    );
    final executable = await File(winget).exists() ? winget : 'gh';
    try {
      final process = await Process.start(executable, [
        'api',
        path,
        '-H',
        path.contains('/releases/assets/')
            ? 'Accept: application/octet-stream'
            : 'Accept: application/vnd.github+json',
      ]);
      _githubProcess = process;
      unawaited(process.stderr.drain<void>());
      Stream<List<int>> output() async* {
        try {
          yield* process.stdout;
          if (await process.exitCode != 0) {
            throw const FormatException(
              'Нет доступа к приватному выпуску. Выполни gh auth login и повтори проверку.',
            );
          }
        } finally {
          process.kill();
          if (_githubProcess == process) _githubProcess = null;
        }
      }

      return http.StreamedResponse(output(), 200);
    } on ProcessException {
      throw const FormatException(
        'Для приватных выпусков установи GitHub CLI и выполни gh auth login.',
      );
    }
  }

  String _assetPath(Map release, String name) {
    final assets = release['assets'];
    if (assets is! List) {
      throw const FormatException('Нет файлов приватного выпуска.');
    }
    final matching = assets
        .whereType<Map>()
        .where((asset) => asset['name'] == name)
        .toList();
    if (matching.length != 1 ||
        matching.single['id'] is! int ||
        matching.single['id'] <= 0) {
      throw const FormatException('Файл приватного выпуска отсутствует.');
    }
    return 'repos/d0rj/mumpa/releases/assets/${matching.single['id']}';
  }

  Future<void> check() async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    status = 'Проверяем обновления…';
    _changed();
    _client = _clientFactory();
    try {
      currentVersion = await _installedVersion();
      final target = await _target();
      // Public release assets avoid the shared unauthenticated API rate limit.
      Map? privateRelease;
      Object? build;
      try {
        build = await _json(
          Uri.parse('$_releaseRoot/latest/download/BUILD.json'),
        );
      } catch (_) {
        if (!_allowPrivateFallback || _disposed) rethrow;
        final release = await _readJson(
          await _githubApi('repos/d0rj/mumpa/releases/latest'),
        );
        if (release is! Map ||
            release['draft'] != false ||
            release['prerelease'] != false) {
          throw const FormatException('Приватный выпуск ещё не опубликован.');
        }
        privateRelease = release;
        build = await _readJson(
          await _githubApi(_assetPath(release, 'BUILD.json')),
        );
      }
      if (build is! Map || build['version'] is! String) {
        throw const FormatException('Некорректные сведения о выпуске.');
      }
      final version = build['version'] as String;
      if (privateRelease != null &&
          privateRelease['tag_name'] != 'v${version.split('+').first}') {
        throw const FormatException(
          'Версия приватного выпуска не совпадает с тегом.',
        );
      }
      final newer = compareVersions(version, currentVersion) > 0;
      if (!newer) {
        available = null;
        downloaded = null;
        status = compareVersions(version, currentVersion) == 0
            ? 'Установлена актуальная версия.'
            : 'Установленная версия новее опубликованной ($version).';
        return;
      }
      final tag = version.split('+').first;
      final fileName = 'Mumpa-$tag-$target';
      final manifest = privateRelease == null
          ? await _json(Uri.parse('$_releaseRoot/download/v$tag/SHA256.json'))
          : await _readJson(
              await _githubApi(_assetPath(privateRelease, 'SHA256.json')),
            );
      if (manifest is! List) {
        throw const FormatException('Некорректные контрольные суммы.');
      }
      final entries = manifest
          .whereType<Map>()
          .where((entry) => entry['file'] == fileName)
          .toList();
      if (entries.length != 1) {
        throw const FormatException('Пакет устройства отсутствует в выпуске.');
      }
      final entry = entries.single;
      final bytes = entry['bytes'], hash = entry['sha256'];
      if (bytes is! int ||
          bytes <= 0 ||
          bytes > 1024 * 1024 * 1024 ||
          hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const FormatException('Некорректные размер или SHA-256 пакета.');
      }
      if (available?.version != version || available?.sha256 != hash) {
        downloaded = null;
      }
      available = AppUpdate(
        version: version,
        fileName: fileName,
        bytes: bytes,
        sha256: hash,
        androidSigning: build['androidSigning'] as String?,
        privateAssetPath: privateRelease == null
            ? null
            : _assetPath(privateRelease, fileName),
      );
      final cached = File(p.join(directory.path, fileName));
      if (await cached.exists() &&
          await cached.length() == bytes &&
          (await sha256.bind(cached.openRead()).first).toString() == hash) {
        downloaded = cached;
      }
      status = downloaded != null
          ? 'Обновление скачано и проверено. Можно установить.'
          : 'Доступна Mumpa $version (${(bytes / 1024 / 1024).toStringAsFixed(1)} МБ).';
    } catch (e) {
      error = _message(e);
      status = 'Не удалось проверить обновления.';
    } finally {
      _client?.close();
      _client = null;
      _githubProcess?.kill();
      busy = false;
      _changed();
    }
  }

  Future<void> download() async {
    final update = available;
    if (busy || update == null || _disposed) return;
    busy = true;
    _cancelled = false;
    received = 0;
    error = null;
    downloaded = null;
    status = 'Скачиваем обновление…';
    _client = _clientFactory();
    _changed();
    final part = File(p.join(directory.path, '${update.fileName}.part'));
    IOSink? sink;
    try {
      await directory.create(recursive: true);
      final response =
          await (update.privateAssetPath == null
                  ? _client!.send(http.Request('GET', update.url))
                  : _githubApi(update.privateAssetPath!))
              .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode} при скачивании.');
      }
      if (response.contentLength != null &&
          response.contentLength != update.bytes) {
        throw const FormatException('Размер скачиваемого пакета не совпадает.');
      }
      sink = part.openWrite();
      final clock = Stopwatch()..start();
      var lastNotice = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        if (_cancelled || _disposed) {
          throw const HttpException('Загрузка отменена.');
        }
        received += chunk.length;
        if (received > update.bytes) {
          throw const FormatException('Пакет больше заявленного размера.');
        }
        sink.add(chunk);
        // Await flush to bound pending disk writes without buffering the ZIP in RAM.
        await sink.flush();
        if (clock.elapsedMilliseconds - lastNotice >= 150) {
          lastNotice = clock.elapsedMilliseconds;
          _changed();
        }
      }
      await sink.close();
      sink = null;
      if (_cancelled || _disposed) {
        throw const HttpException('Загрузка отменена.');
      }
      if (received != update.bytes ||
          (await sha256.bind(part.openRead()).first).toString() !=
              update.sha256) {
        throw const FormatException(
          'Проверка SHA-256 или размера не прошла. Повтори скачивание.',
        );
      }
      final destination = File(p.join(directory.path, update.fileName));
      if (await destination.exists()) await destination.delete();
      downloaded = await part.rename(destination.path);
      status = 'Обновление скачано и проверено. Можно установить.';
    } catch (e) {
      error = _cancelled ? null : _message(e);
      status = _cancelled
          ? 'Загрузка отменена.'
          : 'Не удалось скачать обновление.';
    } finally {
      await sink?.close();
      if (await part.exists()) await part.delete();
      _client?.close();
      _client = null;
      busy = false;
      _changed();
    }
  }

  void cancelDownload() {
    _cancelled = true;
    _client?.close();
    _githubProcess?.kill();
  }

  Future<void> install({required Future<void> Function() quit}) async {
    final update = available, package = downloaded;
    if (busy || update == null || package == null || _disposed) return;
    busy = true;
    error = null;
    status = 'Готовим установку…';
    _changed();
    try {
      if (await package.length() != update.bytes ||
          (await sha256.bind(package.openRead()).first).toString() !=
              update.sha256) {
        downloaded = null;
        throw const FormatException('Пакет изменён. Скачай обновление снова.');
      }
      if (Platform.isAndroid) {
        await _updateChannel.invokeMethod<void>('install', {
          'path': package.path,
        });
        status = 'Подтверди установку в системном окне Android.';
        return;
      }
      if (!Platform.isWindows) {
        throw const FormatException('Установка не поддерживается.');
      }
      final helper = Directory(p.join(directory.path, 'helper'));
      await helper.create(recursive: true);
      for (final name in ['install-windows.ps1', 'uninstall-windows.ps1']) {
        await File(
          p.join(helper.path, name),
        ).writeAsString(await rootBundle.loadString('assets/updater/$name'));
      }
      final receipt = File(p.join(directory.path, 'install-status.json'));
      if (await receipt.exists()) await receipt.delete();
      final executable = p.join(
        Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final process = await Process.start(executable, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        p.join(helper.path, 'install-windows.ps1'),
        '-ZipPath',
        package.path,
        '-Sha256',
        update.sha256,
        '-Version',
        update.version,
        '-WaitForProcessId',
        '$pid',
        '-StatusPath',
        receipt.path,
        '-Launch',
      ], mode: ProcessStartMode.detached);
      // The helper extracts and validates before asking the app to shut down.
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (_disposed) return;
        if (!await receipt.exists()) continue;
        final result =
            jsonDecode(
                  (await receipt.readAsString()).replaceFirst('\uFEFF', ''),
                )
                as Map;
        if (result['state'] == 'failed') {
          throw FormatException(result['message'] as String);
        }
        if (result['state'] == 'ready') {
          status = 'Перезапускаем Mumpa для установки…';
          _changed();
          await quit();
          return;
        }
      }
      process.kill();
      throw const FormatException('Установщик не ответил. Повтори установку.');
    } catch (e) {
      error = _message(e);
      status = 'Не удалось установить обновление.';
    } finally {
      busy = false;
      _changed();
    }
  }

  String _message(Object e) => e is FormatException
      ? e.message
      : e is HttpException
      ? e.message
      : e is PlatformException && e.message != null
      ? e.message!
      : 'Проверь подключение к интернету и повтори попытку.';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _client?.close();
    _githubProcess?.kill();
    super.dispose();
  }
}
