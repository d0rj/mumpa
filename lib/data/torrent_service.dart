import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../domain/models.dart';

Future<bool> _validBinaryHash(String path, String expected) => Isolate.run(
  () async =>
      (await sha256.bind(File(path).openRead()).first).toString() == expected,
);
Future<bool> _validAssetHash(Uint8List bytes, String expected) =>
    Isolate.run(() => sha256.convert(bytes).toString() == expected);

class TorrentEngine {
  TorrentEngine(this.root, {this.binaryDirectory});
  final Directory root;
  final Directory? binaryDirectory;
  Process? _process;
  int? _port;
  Future<String>? _starting;
  static const _channel = MethodChannel('app.mumpa/engine');
  Future<String> start() => _starting ??= _start().catchError((Object e) {
    _starting = null;
    throw e;
  });
  Future<String> _start() async {
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
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = socket.port;
    await socket.close();
    if (Platform.isAndroid) {
      await _channel.invokeMethod('start', {
        'port': _port,
        'directory': state.path,
      });
    } else if (Platform.isWindows) {
      const expected =
          '778bbc9bffb2e4d837a3a2c470fc2a4048d30f0a2004eb2553cd4a495b1bb2d6';
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
      _process = await Process.start(binary.path, [
        '-p',
        '$_port',
        '-i',
        '127.0.0.1',
        '-d',
        state.path,
        '-l',
        p.join(state.path, 'server.log'),
      ]);
      _process!.stdout.drain<void>();
      _process!.stderr.drain<void>();
      final process = _process!;
      unawaited(
        process.exitCode.then((_) {
          if (identical(_process, process)) {
            _starting = null;
            _process = null;
          }
        }),
      );
    } else {
      throw UnsupportedError(
        'Встроенный движок доступен на Windows и Android.',
      );
    }
    final url = 'http://127.0.0.1:$_port';
    final client = http.Client();
    try {
      for (var i = 0; i < 100; i++) {
        try {
          final response = await client
              .get(Uri.parse('$url/echo'))
              .timeout(const Duration(seconds: 1));
          if (response.statusCode == 200) return url;
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      throw StateError(
        'Торрент-движок не запустился. Проверьте журнал в ${state.path}.',
      );
    } finally {
      client.close();
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('stop');
    }
    final process = _process;
    process?.kill();
    if (process != null) {
      await process.exitCode.timeout(const Duration(seconds: 5));
    }
    _process = null;
    _starting = null;
  }
}

class TorrentService {
  TorrentService({required this.endpoint, this.sources, http.Client? client})
    : client = client ?? http.Client();
  final Future<String> Function() endpoint;
  final Directory? sources;
  final http.Client client;
  Future<Uri> _uri(String route) async =>
      Uri.parse('${(await endpoint()).replaceFirst(RegExp(r'/+$'), '')}$route');
  Future<Map<String, dynamic>> _request(Map<String, dynamic> data) async {
    final response = await client
        .post(
          await _uri('/torrents'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 30));
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

  Future<TorrentInfo> add(String link, {String? title}) async {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || !{'magnet', 'http', 'https'}.contains(uri.scheme)) {
      throw const FormatException(
        'Вставьте magnet-ссылку или HTTP-ссылку на .torrent.',
      );
    }
    final result = await _request({
      'action': 'add',
      'link': link.trim(),
      'title': title ?? '',
      'save_to_db': true,
      'category': 'music',
    });
    return _waitFiles(result['hash'] as String);
  }

  Future<TorrentInfo> upload(String path) async {
    final request = http.MultipartRequest(
      'POST',
      await _uri('/torrent/upload'),
    );
    request.fields.addAll({'save': 'true', 'category': 'music'});
    request.files.add(await http.MultipartFile.fromPath('file', path));
    final response = await http.Response.fromStream(
      await client.send(request).timeout(const Duration(seconds: 30)),
    );
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
    return _waitFiles(hash);
  }

  Future<TorrentInfo> get(String hash) async =>
      TorrentInfo.fromJson(await _request({'action': 'get', 'hash': hash}));
  Future<TorrentInfo> _waitFiles(String hash) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      final info = await get(hash);
      if (info.files.isNotEmpty) return info;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    throw const HttpException(
      'Не удалось получить список файлов: нет доступных пиров или метаданных. Попробуйте .torrent вместо magnet.',
    );
  }

  Future<Uri> stream(String hash, int index) async {
    final uri = await _uri('/stream');
    return uri.replace(
      queryParameters: {'link': hash, 'index': '$index', 'play': ''},
    );
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

/// Torznab is optional: the user chooses their own music indexers.
class IndexerService {
  IndexerService({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  Future<List<SearchRelease>> search(
    String endpoint,
    String key,
    String query,
  ) async {
    final uri = Uri.parse(endpoint);
    if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('Укажите URL Torznab API в настройках.');
    }
    final r = await client
        .get(
          uri.replace(
            queryParameters: {
              ...uri.queryParameters,
              't': 'search',
              'q': query,
              'cat': '3000',
              if (key.isNotEmpty) 'apikey': key,
            },
          ),
        )
        .timeout(const Duration(seconds: 25));
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
          return SearchRelease(
            title: item.getElement('title')?.innerText ?? 'Альбом',
            link:
                attrs['magneturl'] ??
                item.getElement('link')?.innerText ??
                item.getElement('enclosure')?.getAttribute('url') ??
                '',
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
