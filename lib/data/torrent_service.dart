import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../domain/models.dart';
import 'source_operation.dart';

Future<bool> _validBinaryHash(String path, String expected) => Isolate.run(
  () async =>
      (await sha256.bind(File(path).openRead()).first).toString() == expected,
);
Future<bool> _validAssetHash(Uint8List bytes, String expected) =>
    Isolate.run(() => sha256.convert(bytes).toString() == expected);

@visibleForTesting
List<int> torrentPeerPortCandidates(int preferred, {Random? random}) {
  final generator = random ?? Random.secure();
  final ports = <int>{if (preferred >= 1024 && preferred <= 65535) preferred};
  while (ports.length < 64) {
    ports.add(1024 + generator.nextInt(65536 - 1024));
  }
  return ports.toList(growable: false);
}

class TorrentEngine {
  TorrentEngine(this.root, {this.binaryDirectory})
    : _executable = null,
      _startProcess = Process.start,
      _clientFactory = http.Client.new,
      _preferredPeerPort = 0,
      _startupTimeout = const Duration(seconds: 30);

  // Exercise lifecycle failures without starting the bundled native executable.
  @visibleForTesting
  TorrentEngine.testing(
    this.root, {
    required File this._executable,
    required this._startProcess,
    required this._clientFactory,
    this._preferredPeerPort = 0,
    this._startupTimeout = const Duration(seconds: 30),
  }) : binaryDirectory = null;

  final Directory root;
  final Directory? binaryDirectory;
  final File? _executable;
  final Future<Process> Function(String, List<String>) _startProcess;
  final http.Client Function() _clientFactory;
  final int _preferredPeerPort;
  final Duration _startupTimeout;
  _EngineProcess? _process;
  Future<String>? _starting;
  Future<void>? _stopping;
  int _generation = 0;
  static const _channel = MethodChannel('app.mumpa/engine');
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
      throw StateError('Запуск торрент-движка отменён.');
    }
  }

  Future<File> _binary(Directory state) async {
    if (_executable != null) return _executable;
    const expected =
        'd94cf58177189d6c01cd7ff7640f7c91b7de7c06cbe4cf48c02ca461d3d97d94';
    final binaries = binaryDirectory ?? state;
    await binaries.create(recursive: true);
    final binary = File(p.join(binaries.path, 'TorrServer-MatriX.145.2.exe'));
    final exists = await binary.exists();
    final valid = exists && await _validBinaryHash(binary.path, expected);
    if (!valid) {
      final asset = await rootBundle.load('assets/engine/TorrServer.exe');
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      if (!await _validAssetHash(bytes, expected)) {
        throw StateError('Не совпадает контрольная сумма торрент-движка.');
      }
      await binary.writeAsBytes(bytes, flush: true);
    }
    return binary;
  }

  Future<String> _start(int generation) async {
    final state = Directory(p.join(root.path, 'engine'));
    await state.create(recursive: true);
    final settings = File(p.join(state.path, 'settings.json'));
    if (!await settings.exists()) {
      // Full nonzero defaults are required: TorrServer does not overlay defaults
      // when loading a partial settings.json. Discovery services are unnecessary
      // for a managed music player, while DHT/PEX and peer transports stay on.
      await settings.writeAsString(
        jsonEncode({
          'BitTorr': {
            'CacheSize': 67108864,
            'PreloadCache': 50,
            'ConnectionsLimit': 25,
            'RetrackersMode': 1,
            'TorrentDisconnectTimeout': 30,
            'ReaderReadAHead': 95,
            'ResponsiveMode': true,
            'ShowFSActiveTorr': true,
            'StoreSettingsInJson': true,
            'EnableLPD': false,
            'LPDIPv6': false,
            'EnableBonjour': false,
            'EnableDLNA': false,
            'DisableUPNP': true,
          },
        }),
        flush: true,
      );
    }
    final android = Platform.isAndroid && _executable == null;
    if (!android && !Platform.isWindows && _executable == null) {
      throw UnsupportedError(
        'Встроенный движок доступен на Windows и Android.',
      );
    }
    // Verify/extract before reserving sockets, retaining the same executable path
    // between launches so Windows Firewall sees a stable binary identity.
    final binary = android ? null : await _binary(state);
    _checkActive(generation);
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    _PeerPort? peer;
    _EngineProcess? process;
    var nativeStartAttempted = false;
    http.Client? client;
    try {
      peer = await _PeerPort.reserve(_preferredPeerPort);
      final torrentPort = peer.port;
      _checkActive(generation);
      // Both transports must accept the chosen peer port. The fork otherwise
      // chooses an ephemeral TCP port first and can fail UDP on Windows reserved
      // ranges. Release immediately before native start; keep HTTP port distinct.
      await peer.close();
      peer = null;
      await socket.close();
      _checkActive(generation);
      if (android) {
        nativeStartAttempted = true;
        await _channel.invokeMethod('start', {
          'port': port,
          'torrentPort': torrentPort,
          'directory': state.path,
        });
      } else {
        final native = await _startProcess(binary!.path, [
          '-p',
          '$port',
          '-i',
          '127.0.0.1',
          '--torrentaddr',
          '0.0.0.0:$torrentPort',
          '-d',
          state.path,
          '-l',
          p.join(state.path, 'server.log'),
        ]);
        process = _EngineProcess(
          native,
          File(p.join(state.path, 'startup.log')),
          port: port,
          torrentPort: torrentPort,
        );
        _process = process;
        final running = process;
        unawaited(
          running.exited.then((_) {
            if (running.ready && identical(_process, running)) {
              _starting = null;
              _process = null;
            }
          }),
        );
      }
      _checkActive(generation);
      final url = 'http://127.0.0.1:$port';
      client = _clientFactory();
      final elapsed = Stopwatch()..start();
      while (elapsed.elapsed < _startupTimeout) {
        _checkActive(generation);
        if (process?.code != null) throw await process!.failure();
        final remaining = _startupTimeout - elapsed.elapsed;
        final requestTimeout = remaining < const Duration(seconds: 1)
            ? remaining
            : const Duration(seconds: 1);
        try {
          final responseFuture = client
              .get(Uri.parse('$url/echo'))
              .timeout(requestTimeout);
          final response = process == null
              ? await responseFuture
              : await Future.any([
                  responseFuture,
                  process.exited.then<http.Response>(
                    (_) async => throw await process!.failure(),
                  ),
                ]);
          _checkActive(generation);
          if (process?.code != null) throw await process!.failure();
          if (response.statusCode == 200) {
            if (process != null) process.ready = true;
            return url;
          }
        } on _EngineExited {
          rethrow;
        } catch (_) {
          _checkActive(generation);
        }
        final delay = Future<void>.delayed(const Duration(milliseconds: 150));
        await (process == null
            ? delay
            : Future.any([
                delay,
                process.exited.then<void>(
                  (_) async => throw await process!.failure(),
                ),
              ]));
      }
      throw StateError(
        'Торрент-движок не ответил за ${_startupTimeout.inSeconds} с. '
        'Проверьте ${p.join(state.path, 'startup.log')} '
        'и ${p.join(state.path, 'server.log')}.',
      );
    } catch (_) {
      if (process != null) {
        await process.stop();
        if (identical(_process, process)) _process = null;
      }
      if (nativeStartAttempted) {
        try {
          await _channel.invokeMethod<void>('stop');
        } catch (_) {}
      }
      rethrow;
    } finally {
      client?.close();
      await peer?.close();
      await socket.close();
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
    if (Platform.isAndroid && _executable == null) {
      await _channel.invokeMethod<void>('stop');
    }
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }
  }
}

class _PeerPort {
  _PeerPort(this.tcp, this.udp);
  final ServerSocket tcp;
  final RawDatagramSocket udp;
  int get port => tcp.port;

  static Future<_PeerPort> reserve(int preferred) async {
    Object? lastError;
    // Windows can exclude entire UDP ephemeral blocks while TCP port=0 walks
    // sequentially through the same block. Spread explicit candidates over the
    // complete unprivileged range instead of repeatedly asking TCP to pick one.
    for (final candidate in torrentPeerPortCandidates(preferred)) {
      ServerSocket? tcp;
      RawDatagramSocket? udp;
      try {
        tcp = await ServerSocket.bind(InternetAddress.anyIPv4, candidate);
        udp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          tcp.port,
          reuseAddress: false,
        );
        return _PeerPort(tcp, udp);
      } on SocketException catch (e) {
        lastError = e;
        udp?.close();
        await tcp?.close();
      }
    }
    throw StateError(
      'Не найден свободный TCP/UDP-порт торрент-движка: $lastError',
    );
  }

  Future<void> close() async {
    udp.close();
    await tcp.close();
  }
}

class _EngineExited extends StateError {
  _EngineExited(super.message);
}

class _EngineProcess {
  _EngineProcess(
    this.process,
    File file, {
    required int port,
    required int torrentPort,
  }) : logPath = file.path,
       _log = file.openWrite(mode: FileMode.append) {
    _log.writeln(
      '\n${DateTime.now().toIso8601String()} '
      'start pid=${process.pid} http=$port peer=$torrentPort',
    );
    // A log I/O error must not become an unhandled background exception.
    unawaited(_log.done.catchError((Object _) {}));
    final stdoutDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) => _record('stdout', chunk))
        .catchError((Object e) => _record('stdout', 'stream error: $e\n'));
    final stderrDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) => _record('stderr', chunk))
        .catchError((Object e) => _record('stderr', 'stream error: $e\n'));
    exited = process.exitCode.then((value) {
      code = value;
      return value;
    });
    _finished = exited.then((value) async {
      try {
        await Future.wait([stdoutDone, stderrDone]);
        _log.writeln('\nexit code=$value');
        await _log.flush();
      } finally {
        await _log.close();
      }
    });
    unawaited(_finished.catchError((Object _) {}));
  }

  final Process process;
  final String logPath;
  final IOSink _log;
  late final Future<int> exited;
  late final Future<void> _finished;
  int? code;
  bool ready = false;
  String _tail = '';

  void _record(String source, String chunk) {
    _tail += chunk;
    if (_tail.length > 4096) _tail = _tail.substring(_tail.length - 4096);
    try {
      _log.write('[$source] $chunk');
    } catch (_) {
      // Preserve in-memory diagnostics even when the log cannot be written.
    }
  }

  Future<_EngineExited> failure() async {
    try {
      await _finished;
    } catch (_) {}
    return _EngineExited(
      'Торрент-движок завершился при запуске (код $code). '
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

class TorrentService {
  TorrentService({
    required this.endpoint,
    this.sources,
    http.Client? client,
    this.audioClientFactory = http.Client.new,
    this.metadataTimeout = const Duration(seconds: 25),
  }) : client = client ?? http.Client();
  final Future<String> Function() endpoint;
  final Directory? sources;
  final http.Client client;
  final http.Client Function() audioClientFactory;
  final Duration metadataTimeout;
  Future<Uri> _uri(String route) async =>
      Uri.parse('${(await endpoint()).replaceFirst(RegExp(r'/+$'), '')}$route');
  Future<Map<String, dynamic>> _request(
    Map<String, dynamic> data, {
    SourceOperation? operation,
  }) async {
    final uri = await _uri('/torrents');
    operation?.check();
    final request =
        http.AbortableRequest(
            'POST',
            uri,
            abortTrigger: operation?.whenCancelled,
          )
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(data);
    final pending = client.send(request).then(http.Response.fromStream);
    final response = await (operation?.wait(pending) ?? pending).timeout(
      const Duration(seconds: 30),
    );
    if (response.statusCode != 200) {
      throw HttpException(
        'TorrServer ${response.statusCode}: ${response.body.substring(0, response.body.length.clamp(0, 200))}',
      );
    }
    final decoded = jsonDecode(response.body);
    return Map<String, dynamic>.from(decoded as Map);
  }

  Future<String> version() async {
    final r = await client
        .get(await _uri('/echo'))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) throw const HttpException('Сервер не отвечает.');
    return r.body;
  }

  Future<TorrentInfo> add(
    String link, {
    String? title,
    SourceOperation? operation,
    void Function(String)? onProgress,
  }) async {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || !{'magnet', 'http', 'https'}.contains(uri.scheme)) {
      throw const FormatException(
        'Вставьте magnet-ссылку или HTTP-ссылку на .torrent.',
      );
    }
    onProgress?.call('Подключаем раздачу…');
    final result = await _request({
      'action': 'add',
      'link': link.trim(),
      'title': title ?? '',
      'save_to_db': true,
      'category': 'music',
    }, operation: operation);
    return _waitFiles(
      result['hash'] as String,
      operation: operation,
      onProgress: onProgress,
    );
  }

  Future<TorrentInfo> upload(
    String path, {
    SourceOperation? operation,
    void Function(String)? onProgress,
  }) async {
    operation?.check();
    onProgress?.call('Читаем список треков из torrent-файла…');
    final request = http.MultipartRequest(
      'POST',
      await _uri('/torrent/upload'),
    );
    request.fields.addAll({'save': 'true', 'category': 'music'});
    request.files.add(await http.MultipartFile.fromPath('file', path));
    operation?.check();
    final pending = client.send(request).then(http.Response.fromStream);
    final response = await (operation?.wait(pending) ?? pending).timeout(
      const Duration(seconds: 20),
    );
    operation?.check();
    if (response.statusCode != 200) {
      throw HttpException(
        'Не удалось добавить .torrent (${response.statusCode}).',
      );
    }
    final result = jsonDecode(response.body);
    final item = result is List ? result.first : result;
    final hash = (item as Map)['hash'] as String;
    if (sources != null) {
      await sources!.create(recursive: true);
      final target = p.join(sources!.path, '${stableId(hash)}.torrent');
      if (!p.equals(p.absolute(path), p.absolute(target))) {
        await File(path).copy(target);
      }
    }
    return _waitFiles(hash, operation: operation, onProgress: onProgress);
  }

  Future<TorrentInfo> get(String hash) async =>
      TorrentInfo.fromJson(await _request({'action': 'get', 'hash': hash}));
  Future<TorrentInfo> _waitFiles(
    String hash, {
    SourceOperation? operation,
    void Function(String)? onProgress,
  }) async {
    final timer = Stopwatch()..start();
    final deadline = DateTime.now().add(metadataTimeout);
    while (DateTime.now().isBefore(deadline)) {
      operation?.check();
      onProgress?.call(
        'Ожидаем список треков от пиров · ${timer.elapsed.inSeconds}/${metadataTimeout.inSeconds} с',
      );
      final pending = _request({
        'action': 'get',
        'hash': hash,
      }, operation: operation);
      Map<String, dynamic> data;
      try {
        data = await (operation?.wait(pending) ?? pending).timeout(
          deadline.difference(DateTime.now()),
        );
      } on TimeoutException {
        break;
      }
      final info = TorrentInfo.fromJson(data);
      if (info.files.isNotEmpty) return info;
      final delay = Future<void>.delayed(const Duration(milliseconds: 700));
      await (operation?.wait(delay) ?? delay);
    }
    throw const HttpException(
      'У раздачи нет доступных метаданных. Выбери раздачу с активными сидами или источник, который отдаёт torrent-файл. Magnet требует ответа пиров.',
    );
  }

  Future<Uri> stream(String hash, int index) async {
    final uri = await _uri('/stream');
    return uri.replace(
      queryParameters: {'link': hash, 'index': '$index', 'play': ''},
    );
  }

  /// Wait for actual payload, rather than HTTP headers from a peerless reader.
  /// Cancelling/expiring this probe aborts its own HTTP request only.
  Future<void> waitForAudio(
    Uri uri, {
    SourceOperation? operation,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final probe = SourceOperation();
    final probeClient = audioClientFactory();
    StreamSubscription<List<int>>? payloadSubscription;
    final deadline = Timer(timeout, probe.cancel);
    final callerCancelled = operation?.whenCancelled.then(
      (_) => probe.cancel(),
    );
    // SourceOperation cancellation futures complete successfully.
    if (callerCancelled != null) unawaited(callerCancelled);
    try {
      operation?.check();
      final response = await probe.wait(
        probeClient.send(
          http.AbortableRequest('GET', uri, abortTrigger: probe.whenCancelled)
            ..headers['Range'] = 'bytes=0-4095',
        ),
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException('Аудиопоток ответил HTTP ${response.statusCode}.');
      }
      final firstBytes = Completer<void>();
      payloadSubscription = response.stream.listen(
        (bytes) {
          if (bytes.isNotEmpty && !firstBytes.isCompleted) {
            firstBytes.complete();
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!firstBytes.isCompleted) firstBytes.completeError(error, stack);
        },
        onDone: () {
          if (!firstBytes.isCompleted) {
            firstBytes.completeError(const HttpException('Аудиопоток пуст.'));
          }
        },
        cancelOnError: true,
      );
      await probe.wait(firstBytes.future);
    } on SourceCancelled {
      operation?.check();
      throw TimeoutException('Раздача не передала первые аудиобайты.', timeout);
    } on http.RequestAbortedException {
      operation?.check();
      throw TimeoutException('Раздача не передала первые аудиобайты.', timeout);
    } on StateError {
      throw const HttpException('Аудиопоток завершился без данных.');
    } on http.ClientException {
      operation?.check();
      throw const HttpException('Не удалось подключиться к аудиопотоку.');
    } finally {
      deadline.cancel();
      probe.cancel();
      // Response-subscription cancellation can drain an unfinished HTTP body.
      // A dedicated client lets us close this stalled socket without affecting
      // metadata requests or the parallel complete-file offline transfer.
      probeClient.close();
      await payloadSubscription?.cancel();
    }
  }

  Future<Uri> resolve(Track track) async {
    try {
      await _waitFiles(track.torrentHash!);
    } on HttpException {
      final metainfo = sources == null
          ? null
          : File(
              p.join(sources!.path, '${stableId(track.torrentHash!)}.torrent'),
            );
      if (metainfo != null && await metainfo.exists()) {
        await upload(metainfo.path);
      } else if (track.torrentLink != null) {
        await add(track.torrentLink!);
      } else {
        rethrow;
      }
    }
    return stream(track.torrentHash!, track.torrentIndex!);
  }

  List<Track> tracks(
    TorrentInfo info, {
    String? link,
    String? album,
    String? artist,
  }) {
    return info.files.where((f) => isAudioPath(f.path)).map((f) {
      final filename = p.posix.basenameWithoutExtension(
        f.path.replaceAll('\\', '/'),
      );
      final number =
          int.tryParse(
            RegExp(r'^(\d{1,3})[ ._\-]').firstMatch(filename)?.group(1) ?? '',
          ) ??
          0;
      return Track(
        id: stableId('${info.hash}:${f.index}'),
        title: filename.replaceFirst(RegExp(r'^\d{1,3}[ ._\-]+'), ''),
        artist: artist?.trim().isNotEmpty == true
            ? artist!.trim()
            : 'Неизвестный исполнитель',
        album: album?.trim().isNotEmpty == true ? album!.trim() : info.title,
        source: TrackSource.torrent,
        torrentHash: info.hash,
        torrentLink: link,
        torrentIndex: f.index,
        torrentPath: f.path,
        bytes: f.bytes,
        number: number,
      );
    }).toList();
  }

  void dispose() => client.close();
}

/// Jackett/Prowlarr Torznab adapter, restricted to the Audio category.
class IndexerService {
  IndexerService({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  Future<List<({String id, String name})>> configuredIndexers(
    String endpoint,
    String key,
  ) async {
    final uri = Uri.parse(endpoint).replace(
      queryParameters: {
        't': 'indexers',
        'configured': 'true',
        if (key.isNotEmpty) 'apikey': key,
      },
    );
    late http.Response response;
    try {
      response = await client.get(uri).timeout(const Duration(seconds: 8));
    } on http.ClientException {
      throw const HttpException('Не удалось подключиться к Jackett.');
    } on TimeoutException {
      throw const HttpException('Jackett не ответил вовремя.');
    }
    if (response.statusCode != 200) return [];
    final xml = XmlDocument.parse(response.body);
    return xml
        .findAllElements('indexer')
        .map(
          (item) => (
            id: item.getAttribute('id') ?? '',
            name:
                item.getElement('title')?.innerText ??
                item.getAttribute('name') ??
                '',
          ),
        )
        .where((item) => item.id.isNotEmpty)
        .toList();
  }

  Future<({String source, bool file})> resolve(
    String link,
    Directory directory, {
    SourceOperation? operation,
  }) async {
    var uri =
        Uri.tryParse(link) ??
        (throw const FormatException('Некорректная ссылка на раздачу.'));
    for (var hop = 0; hop < 6; hop++) {
      operation?.check();
      if (uri.scheme == 'magnet') return (source: uri.toString(), file: false);
      if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
        throw const FormatException(
          'Источник должен возвращать magnet или torrent-файл.',
        );
      }
      http.StreamedResponse response;
      try {
        response = await client
            .send(
              http.AbortableRequest(
                'GET',
                uri,
                abortTrigger: operation?.whenCancelled,
              )..followRedirects = false,
            )
            .timeout(const Duration(seconds: 25));
      } on http.ClientException {
        operation?.check();
        throw const HttpException(
          'Не удалось получить раздачу из Jackett. Проверь соединение и настройки трекера.',
        );
      }
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.drain<void>();
        if (location == null) {
          throw const HttpException('Jackett вернул переход без адреса.');
        }
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw HttpException(
          'Не удалось получить torrent-файл: HTTP ${response.statusCode}.',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 25),
      )) {
        operation?.check();
        bytes.add(chunk);
        if (bytes.length > 16 * 1024 * 1024) {
          throw const FormatException('Torrent-файл превышает 16 МБ.');
        }
      }
      final data = bytes.takeBytes();
      if (data.isEmpty || data.first != 100 || data.last != 101) {
        throw const FormatException(
          'Jackett вернул страницу вместо torrent-файла. Проверь доступ к раздаче.',
        );
      }
      await directory.create(recursive: true);
      operation?.check();
      final file = File(
        p.join(directory.path, 'source-${stableId(link)}.torrent'),
      );
      await file.writeAsBytes(data, flush: true);
      return (source: file.path, file: true);
    }
    throw const HttpException('Слишком много переходов при получении раздачи.');
  }

  Future<void> check(String endpoint, String key) async {
    final uri = Uri.tryParse(endpoint);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('Укажи корректный HTTP/HTTPS адрес Jackett.');
    }
    final response = await client
        .get(
          uri.replace(
            queryParameters: {
              ...uri.queryParameters,
              't': 'caps',
              if (key.isNotEmpty) 'apikey': key,
            },
          ),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException(
        'Jackett ответил HTTP ${response.statusCode}. Проверь адрес и API key.',
      );
    }
    final xml = XmlDocument.parse(response.body);
    final error = xml.findAllElements('error').firstOrNull;
    if (error != null) {
      throw HttpException(
        error.getAttribute('description') ?? 'Jackett не принял подключение.',
      );
    }
    if (xml.rootElement.name.local != 'caps') {
      throw const FormatException(
        'Это не Torznab API. Укажи адрес Jackett или ссылку Torznab.',
      );
    }
  }

  Future<List<SearchRelease>> search(
    String endpoint,
    String key,
    String query, {
    SourceOperation? operation,
  }) async {
    final uri = Uri.parse(endpoint);
    if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('Укажите URL Torznab API в настройках.');
    }
    operation?.check();
    final request = http.AbortableRequest(
      'GET',
      uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          't': 'search',
          'q': query,
          'cat': '3000',
          if (key.isNotEmpty) 'apikey': key,
        },
      ),
      abortTrigger: operation?.whenCancelled,
    );
    late http.Response r;
    try {
      final pending = client.send(request).then(http.Response.fromStream);
      r = await (operation == null ? pending : operation.wait(pending)).timeout(
        const Duration(seconds: 80),
      );
    } on http.ClientException {
      operation?.check();
      throw const HttpException('Не удалось подключиться к Jackett.');
    } on TimeoutException {
      throw const HttpException(
        'Поиск не завершился за 80 секунд. Проверь трекер и FlareSolverr в Jackett.',
      );
    }
    operation?.check();
    if (r.statusCode != 200) {
      throw HttpException('Индексатор вернул ${r.statusCode}.');
    }
    final xml = XmlDocument.parse(r.body);
    final error = xml.findAllElements('error').firstOrNull;
    if (error != null) {
      throw HttpException(
        error.getAttribute('description') ?? 'Ошибка индексатора',
      );
    }
    return xml
        .findAllElements('item')
        .map((item) {
          final attrs = {
            for (final e in item.descendants.whereType<XmlElement>().where(
              (e) => e.name.local == 'attr',
            ))
              e.getAttribute('name'): e.getAttribute('value'),
          };
          final links = [
            item.getElement('link')?.innerText,
            item.getElement('enclosure')?.getAttribute('url'),
            attrs['magneturl'],
          ].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
          final download = links
              .where((s) => {'http', 'https'}.contains(Uri.tryParse(s)?.scheme))
              .firstOrNull;
          final indexer = item.getElement('jackettindexer');
          var title = item.getElement('title')?.innerText ?? 'Альбом';
          if (indexer?.getAttribute('id') == 'rutracker' ||
              (indexer?.innerText.toLowerCase().contains('rutracker.org') ??
                  false)) {
            // Jackett's default Sonarr title filter removes Cyrillic letters.
            // RuTracker also supplies its full original title after the uploader
            // line in description; keep it without changing the user's indexer.
            final description = html_parser.parseFragment(
              item.getElement('description')?.innerText ?? '',
            );
            final divider = description.nodes.indexWhere(
              (node) => node is html_dom.Element && node.localName == 'br',
            );
            if (divider >= 0) {
              final original = description.nodes
                  .skip(divider + 1)
                  .map((node) => node.text ?? '')
                  .join()
                  .trim();
              if (original.isNotEmpty) title = original;
            }
          }
          return SearchRelease(
            title: title,
            link: download ?? links.firstOrNull ?? '',
            magnetLink: attrs['magneturl'],
            indexerName: indexer?.innerText ?? '',
            detailsUrl: item.getElement('comments')?.innerText ?? '',
            seedersKnown: attrs['seeders'] != null,
            bytes:
                int.tryParse(
                  attrs['size'] ?? item.getElement('size')?.innerText ?? '',
                ) ??
                0,
            seeders: int.tryParse(attrs['seeders'] ?? '') ?? 0,
          );
        })
        .where((item) => item.link.isNotEmpty)
        .toList();
  }

  void dispose() => client.close();
}
