import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:enough_convert/windows.dart';
import '../domain/models.dart';

/// A metadata cache may retain older announce URLs than the search magnet.
/// Preserve the exact info bytes (and therefore content identity), adding only
/// the public tracker URLs already supplied by the selected source.
Uint8List addMagnetTrackers(Uint8List bytes, Uri magnet) {
  final additions = <String>{};
  for (final value
      in (magnet.queryParametersAll['tr'] ?? const <String>[]).take(32)) {
    final uri = Uri.tryParse(value);
    if (value.length <= 2048 &&
        uri != null &&
        uri.host.isNotEmpty &&
        {'http', 'https', 'udp', 'wss'}.contains(uri.scheme)) {
      additions.add(value);
    }
  }
  if (additions.isEmpty) return bytes;
  // Bounds, safe paths and v1 info are validated before changing the envelope.
  final original = readTorrentMetainfo(bytes);
  final reader = _BencodeReader(bytes);
  final data = Map<String, Object>.from(reader.read() as Map);
  String? text(Object? value) =>
      value is Uint8List ? utf8.decode(value, allowMalformed: true) : null;
  final previous = <String>{
    if (text(data['announce']) case final String value) value,
    if (data['announce-list'] case final List tiers)
      for (final tier in tiers.whereType<List>())
        for (final value in tier)
          if (text(value) case final String url) url,
  };
  if (additions.every(previous.contains)) return bytes;
  final trackers = {...additions, ...previous};
  data['announce'] = trackers.first;
  data['announce-list'] = trackers.map((url) => [url]).toList();
  Uint8List encode(Object value) {
    if (value is int) return Uint8List.fromList(ascii.encode('i${value}e'));
    if (value is String) return encode(Uint8List.fromList(utf8.encode(value)));
    if (value is Uint8List) {
      return Uint8List.fromList([
        ...ascii.encode('${value.length}:'),
        ...value,
      ]);
    }
    if (value is List) {
      return Uint8List.fromList([
        108,
        ...value.expand((item) => encode(item as Object)),
        101,
      ]);
    }
    final map = value as Map<String, Object>;
    final keys = map.keys.toList()..sort();
    return Uint8List.fromList([
      100,
      ...keys.expand((key) => [...encode(key), ...encode(map[key]!)]),
      101,
    ]);
  }

  final keys = data.keys.toList()..sort();
  final result = Uint8List.fromList([
    100,
    ...keys.expand(
      (key) => [
        ...encode(key),
        if (key == 'info')
          ...Uint8List.sublistView(bytes, reader.infoStart!, reader.infoEnd!)
        else
          ...encode(data[key]!),
      ],
    ),
    101,
  ]);
  if (readTorrentMetainfo(result).hash != original.hash) {
    throw const FormatException('Tracker merge changed content identity');
  }
  return result;
}

/// Reads file names without starting an engine or downloading audio pieces.
/// IDs are one-based metainfo ordinals, not native TorrServer IDs: the server
/// sorts its file list. Resolve a selected file by full path after upload and
/// use the server's returned ID for streaming; the original ordinals are safe
/// immutable cache identities within this exact info hash.
TorrentInfo readTorrentMetainfo(Uint8List bytes) {
  if (bytes.length > 16 * 1024 * 1024) {
    throw const FormatException('Torrent-файл превышает 16 МБ.');
  }
  final reader = _BencodeReader(bytes);
  final data = reader.read();
  if (reader.offset != bytes.length ||
      data is! Map ||
      data['info'] is! Map ||
      reader.infoStart == null) {
    throw const FormatException('Некорректная метаинформация .torrent.');
  }
  final info = data['info'] as Map;
  if (info['pieces'] is! Uint8List) {
    throw const FormatException(
      'Поиск по файлам пока поддерживает BitTorrent v1 и hybrid .torrent.',
    );
  }
  String text(Object? value) {
    if (value is! Uint8List) {
      throw const FormatException('В torrent-файле нет имени.');
    }
    try {
      return utf8.decode(value);
    } catch (_) {
      return const Windows1251Codec().decode(value);
    }
  }

  String safe(Object? value) {
    final name = text(value);
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000')) {
      throw const FormatException('Недопустимое имя в torrent-файле.');
    }
    return name;
  }

  int length(Object? value) {
    if (value is! int || value < 0) {
      throw const FormatException('Некорректный размер файла.');
    }
    return value;
  }

  final name = safe(info['name.utf-8'] ?? info['name']);
  final files = <TorrentFile>[];
  if (info['files'] is List) {
    final raw = info['files'] as List;
    if (raw.length > 30000) {
      throw const FormatException('В раздаче слишком много файлов.');
    }
    for (final (i, item) in raw.indexed) {
      if (item is! Map) {
        throw const FormatException('Некорректный список файлов.');
      }
      final path = item['path.utf-8'] ?? item['path'];
      if (path is! List || path.isEmpty) {
        throw const FormatException('Некорректный путь файла.');
      }
      files.add(
        TorrentFile(
          index: i + 1,
          path: '$name/${path.map(safe).join('/')}',
          bytes: length(item['length']),
        ),
      );
    }
  } else {
    files.add(TorrentFile(index: 1, path: name, bytes: length(info['length'])));
  }
  return TorrentInfo(
    hash: sha1
        .convert(
          Uint8List.sublistView(bytes, reader.infoStart!, reader.infoEnd!),
        )
        .toString(),
    title: name,
    files: List.unmodifiable(files),
  );
}

class _BencodeReader {
  _BencodeReader(this.bytes);
  final Uint8List bytes;
  int offset = 0, nodes = 0;
  int? infoStart, infoEnd;
  Object read([int depth = 0]) {
    if (depth > 64 || ++nodes > 300000 || offset >= bytes.length) {
      throw const FormatException('Некорректный bencode.');
    }
    final token = bytes[offset];
    if (token == 105) {
      final start = ++offset;
      while (offset < bytes.length && bytes[offset] != 101) {
        offset++;
      }
      if (offset >= bytes.length || offset - start > 20) {
        throw const FormatException('Некорректное число bencode.');
      }
      final value = int.tryParse(
        ascii.decode(Uint8List.sublistView(bytes, start, offset++)),
      );
      if (value == null) {
        throw const FormatException('Некорректное число bencode.');
      }
      return value;
    }
    if (token == 108 || token == 100) {
      offset++;
      final list = <Object>[];
      final dict = <String, Object>{};
      while (offset < bytes.length && bytes[offset] != 101) {
        if (token == 108) {
          list.add(read(depth + 1));
        } else {
          final keyBytes = read(depth + 1);
          if (keyBytes is! Uint8List) {
            throw const FormatException('Некорректный ключ bencode.');
          }
          final key = utf8.decode(keyBytes, allowMalformed: true);
          if (dict.containsKey(key)) {
            throw const FormatException('Повторный ключ bencode.');
          }
          final start = offset;
          dict[key] = read(depth + 1);
          if (depth == 0 && key == 'info') {
            infoStart = start;
            infoEnd = offset;
          }
        }
      }
      if (offset >= bytes.length) {
        throw const FormatException('Незавершённый bencode.');
      }
      offset++;
      return token == 108 ? list : dict;
    }
    final start = offset;
    while (offset < bytes.length &&
        bytes[offset] >= 48 &&
        bytes[offset] <= 57) {
      offset++;
    }
    if (offset == start ||
        offset >= bytes.length ||
        bytes[offset] != 58 ||
        offset - start > 8) {
      throw const FormatException('Некорректная строка bencode.');
    }
    final length = int.tryParse(
      ascii.decode(Uint8List.sublistView(bytes, start, offset++)),
    );
    if (length == null || length < 0 || offset + length > bytes.length) {
      throw const FormatException('Незавершённая строка bencode.');
    }
    final value = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return value;
  }
}
