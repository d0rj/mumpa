import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../domain/models.dart';
import 'library_repository.dart';
import 'profile_transfer.dart';

class LanTransferServer {
  LanTransferServer._(this.server, this.token, this.manifest, this.files) {
    _expiry = Timer(const Duration(minutes: 10), () => unawaited(close()));
    _subscription = server.listen(_serve);
  }
  final HttpServer server;
  final String token;
  final Map<String, dynamic> manifest;
  final Map<String, File> files;
  Timer? _expiry;
  StreamSubscription<HttpRequest>? _subscription;
  bool closed = false;
  int _clients = 0;
  Uri address(String host) =>
      Uri(scheme: 'http', host: host, port: server.port, fragment: token);
  static Future<List<String>> localAddresses() async => [
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    ))
      for (final address in interface.addresses)
        if (isPrivateAddress(address.address)) address.address,
  ];
  static bool isPrivateAddress(String host) {
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((x) => x == null || x < 0 || x > 255)) {
      return false;
    }
    return parts[0] == 10 ||
        parts[0] == 127 ||
        parts[0] == 192 && parts[1] == 168 ||
        parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31;
  }

  static Future<LanTransferServer> start(
    LibraryRepository library,
    Iterable<Track> selected, {
    InternetAddress? bindAddress,
    bool Function()? cancelled,
  }) async {
    final files = <String, File>{}, rows = <Map<String, dynamic>>[];
    for (final track in selected) {
      if (cancelled?.call() == true) throw StateError('Передача отменена');
      if (files.containsKey(track.id)) continue;
      final path = await library.localPathFor(track);
      if (path == null) continue;
      final file = File(path);
      final bytes = await file.length();
      final digest = await sha256
          .bind(
            file.openRead().map((chunk) {
              if (cancelled?.call() == true) {
                throw StateError('Передача отменена');
              }
              return chunk;
            }),
          )
          .first;
      files[track.id] = file;
      rows.add({
        'id': track.id,
        'extension': p.extension(path).toLowerCase(),
        'bytes': bytes,
        'sha256': '$digest',
      });
    }
    final profile = await library.exportProfile();
    final manifest = <String, dynamic>{
      'format': 'mumpa-lan',
      'version': 1,
      'profile': profile,
      'files': rows,
    };
    if (utf8.encode(jsonEncode(manifest)).length >
        ProfileTransfer.maxBytes + 4 * 1024 * 1024) {
      throw const FormatException('Слишком большой профиль для передачи.');
    }
    final token = base64Url
        .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    final server = await HttpServer.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      0,
    );
    return LanTransferServer._(server, token, manifest, files);
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (closed ||
          request.method != 'GET' ||
          request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer $token') {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (_clients >= 2) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        return;
      }
      ++_clients;
      try {
        if (request.uri.path == '/manifest') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(manifest));
        } else {
          final file =
              files[request.uri.path.replaceFirst(RegExp(r'^/audio/'), '')];
          if (!request.uri.path.startsWith('/audio/') || file == null) {
            request.response.statusCode = HttpStatus.notFound;
            return;
          }
          request.response.contentLength = await file.length();
          request.response.headers.contentType = ContentType.binary;
          await request.response.addStream(file.openRead());
        }
      } finally {
        --_clients;
      }
    } catch (_) {
      /* A cancelled peer must not leave an unhandled async error. */
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    _expiry?.cancel();
    await server.close(force: true);
    await _subscription?.cancel();
  }
}

class LanTransferClient {
  LanTransferClient(String link)
    : address = Uri.parse(link).replace(
        scheme: Uri.parse(link).scheme == 'mumpa-transfer'
            ? 'http'
            : Uri.parse(link).scheme,
      ) {
    if (address.scheme != 'http' ||
        !LanTransferServer.isPrivateAddress(address.host) ||
        address.userInfo.isNotEmpty ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(address.fragment)) {
      throw const FormatException(
        'Нужна ссылка передачи Mumpa из локальной сети.',
      );
    }
  }
  final Uri address;
  static LanTransferClient? tryCreate(String link) {
    try {
      return LanTransferClient(link);
    } catch (_) {
      return null;
    }
  }

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  bool _closed = false;
  Future<HttpClientResponse> _get(String path) async {
    if (_closed) throw StateError('Передача отменена');
    final request = await _http
        .getUrl(address.replace(path: path, fragment: '', query: ''))
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${address.fragment}',
    );
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw const HttpException(
        'Передача недоступна. Проверь ссылку и открой её заново на отправителе.',
      );
    }
    return response;
  }

  Future<Map<String, dynamic>> preview() async {
    final response = await _get('/manifest');
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.addAll(chunk);
      if (bytes.length > ProfileTransfer.maxBytes + 4 * 1024 * 1024) {
        throw const FormatException('Слишком большой профиль.');
      }
    }
    final manifest = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (manifest['format'] != 'mumpa-lan' ||
        manifest['version'] != 1 ||
        manifest['profile'] is! String ||
        manifest['files'] is! List ||
        (manifest['files'] as List).length > 10000) {
      throw const FormatException('Неизвестный формат передачи.');
    }
    validateManifest(manifest);
    return manifest;
  }

  static void validateManifest(Map<String, dynamic> manifest) {
    if (manifest['format'] != 'mumpa-lan' ||
        manifest['version'] != 1 ||
        manifest['profile'] is! String ||
        manifest['files'] is! List ||
        (manifest['files'] as List).length > 10000) {
      throw const FormatException('Неизвестный формат передачи.');
    }
    final profile = ProfileTransfer.decode(manifest['profile'] as String);
    final profileIds = profile.trackIds;
    final ids = <String>{};
    for (final row in manifest['files'] as List) {
      if (row is! Map ||
          row['id'] is! String ||
          !profileIds.contains(row['id']) ||
          !RegExp(r'^[a-zA-Z0-9:_-]{1,128}$').hasMatch(row['id'] as String) ||
          !ids.add(row['id'] as String) ||
          row['extension'] is! String ||
          !isAudioPath('track${row['extension']}') ||
          !RegExp(r'^\.[a-z0-9]+$').hasMatch(row['extension'] as String) ||
          row['bytes'] is! int ||
          (row['bytes'] as int) < 0 ||
          (row['bytes'] as int) > 20 * 1024 * 1024 * 1024 ||
          row['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(row['sha256'] as String)) {
        throw const FormatException('Повреждённый список файлов.');
      }
    }
  }

  Future<void> receive(
    LibraryRepository library,
    Map<String, dynamic> manifest, {
    bool includeAudio = true,
    void Function(int, int)? progress,
  }) async {
    if (_closed) throw StateError('Передача отменена');
    validateManifest(manifest);
    final transfer = ProfileTransfer.decode(manifest['profile'] as String);
    // Profile restore is additive and makes its ordinary pre-import backup.
    await library.importProfile(transfer);
    final rows = includeAudio ? manifest['files'] as List : [];
    var done = 0;
    for (final raw in rows) {
      if (_closed) throw StateError('Передача отменена');
      final row = raw as Map;
      final track = library.byId(row['id'] as String);
      if (track == null) {
        throw const FormatException('В профиле нет передаваемого трека.');
      }
      if (await library.localPathFor(track) != null) {
        progress?.call(++done, rows.length);
        continue;
      }
      final directory = Directory(p.join(library.root.path, 'imports'));
      await directory.create(recursive: true);
      final target = File(
        p.join(directory.path, '${row['sha256']}${row['extension']}'),
      );
      final partial = File(
        '${target.path}.lan-${DateTime.now().microsecondsSinceEpoch}.part',
      );
      try {
        final response = await _get('/audio/${row['id']}');
        var received = 0;
        final sink = partial.openWrite();
        try {
          await for (final chunk in response.timeout(
            const Duration(seconds: 30),
          )) {
            received += chunk.length;
            if (received > (row['bytes'] as int)) {
              throw const FormatException('Размер файла не совпал.');
            }
            sink.add(chunk);
            await sink.flush();
          }
        } finally {
          await sink.close();
        }
        if (received != row['bytes'] ||
            '${await sha256.bind(partial.openRead()).first}' != row['sha256']) {
          throw const FormatException('Проверка SHA-256 не пройдена.');
        }
        if (_closed) throw StateError('Передача отменена');
        if (!await target.exists()) {
          await partial.rename(target.path);
        } else if ('${await sha256.bind(target.openRead()).first}' !=
            row['sha256']) {
          throw const FormatException(
            'Существующий файл не совпадает с передаваемым.',
          );
        }
        if (track.source == TrackSource.local) {
          await library.upsert([
            track.copyWith(localPath: target.path),
          ], addToLibrary: true);
        } else {
          await library.upsert([
            track.copyWith(
              cachedPath: target.path,
              downloadedAt: DateTime.now().toUtc(),
            ),
          ], addToLibrary: true);
        }
      } finally {
        if (await partial.exists()) await partial.delete();
      }
      progress?.call(++done, rows.length);
    }
  }

  void close() {
    _closed = true;
    _http.close(force: true);
  }
}
