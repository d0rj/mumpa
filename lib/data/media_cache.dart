import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class CacheStats {
  const CacheStats({
    required this.bytes,
    required this.count,
    required this.maxBytes,
  });

  final int bytes, count, maxBytes;
}

/// A persistent FIFO cache shared by music metadata and artwork.
///
/// Reads do not change insertion order. The index stores only hashed keys,
/// never request URLs, and owns files exclusively in its `files` subdirectory.
class DiskMediaCache {
  DiskMediaCache(
    this.root, {
    int maxBytes = 256 * 1024 * 1024,
    DateTime Function()? clock,
  }) : _maxBytes = maxBytes,
       _clock = clock ?? DateTime.now {
    if (maxBytes < 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'Must be non-negative');
    }
  }

  final Directory root;
  final DateTime Function() _clock;
  final Map<String, _CacheEntry> _entries = {};
  Future<void> _tail = Future.value();
  bool _initialized = false;
  int _maxBytes;
  int _generation = 0;
  int _nextSequence = 0;

  /// Capture this before fetching. Pass it to [put] to respect [clear].
  int get generation => _generation;
  Directory get _files => Directory(p.join(root.absolute.path, 'files'));
  File get _index => File(p.join(root.absolute.path, 'index.json'));
  int get _bytes => _entries.values.fold(0, (sum, entry) => sum + entry.bytes);

  static final _hashPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _filePattern = RegExp(r'^[a-f0-9]{64}\.[a-z0-9]{1,10}$');

  String _hash(String key) => sha256.convert(utf8.encode(key)).toString();
  File _file(_CacheEntry entry) => File(p.join(_files.path, entry.filename));
  bool _expired(_CacheEntry entry) =>
      entry.expiresAt != null && !_clock().toUtc().isBefore(entry.expiresAt!);

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _tail.then((_) async {
      await _ensureInitialized();
      return operation();
    });
    // One failed I/O operation must not poison every later cache operation.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> initialize() => _serialize(() async {});

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _entries.clear();
    _nextSequence = 0;
    for (final directory in [root, _files]) {
      if (await FileSystemEntity.type(directory.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw FileSystemException(
          'Cache directory cannot be a link',
          directory.path,
        );
      }
      await directory.create(recursive: true);
    }
    if (await _index.exists()) {
      try {
        final saved = jsonDecode(await _index.readAsString());
        if (saved is Map && saved['entries'] is List) {
          for (final item in saved['entries'] as List) {
            final entry = _CacheEntry.parse(item);
            if (entry == null ||
                !_hashPattern.hasMatch(entry.hash) ||
                !_filePattern.hasMatch(entry.filename) ||
                !entry.filename.startsWith('${entry.hash}.')) {
              continue;
            }
            if (_expired(entry)) continue;
            final file = _file(entry);
            if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file) {
              continue;
            }
            final length = await file.length();
            // Partial writes or tampered entries are not usable cached data.
            if (length != entry.bytes) continue;
            _entries[entry.hash] = entry;
            if (entry.sequence >= _nextSequence) {
              _nextSequence = entry.sequence + 1;
            }
          }
        }
      } on FormatException {
        // Interrupted/corrupt indexes recover to an empty, usable cache.
      }
    }
    await _removeOrphans();
    await _evict();
    await _writeIndex();
    _initialized = true;
  }

  Future<void> _removeOrphans() async {
    final keep = _entries.values.map((entry) => entry.filename).toSet();
    await for (final entity in _files.list(followLinks: false)) {
      final filename = p.basename(entity.path);
      final temporary = filename.endsWith('.tmp')
          ? filename.substring(0, filename.length - 4)
          : null;
      final owned =
          _filePattern.hasMatch(filename) ||
          (temporary != null && _filePattern.hasMatch(temporary));
      if (owned && !keep.contains(filename) && entity is! Directory) {
        await entity.delete();
      }
    }
  }

  Future<void> _writeIndex() async {
    final temporary = File('${_index.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'entries': _entries.values.map((entry) => entry.toJson()).toList(),
      }),
      flush: true,
    );
    await temporary.rename(_index.path);
  }

  Future<void> _deleteEntry(String hash) async {
    final entry = _entries.remove(hash);
    if (entry == null) return;
    final file = _file(entry);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      await file.delete();
    }
  }

  Future<void> _evict() async {
    for (final entry in _entries.values.toList()) {
      if (_expired(entry)) await _deleteEntry(entry.hash);
    }
    final oldest = _entries.values.toList()
      ..sort((a, b) {
        final date = a.createdAt.compareTo(b.createdAt);
        return date != 0 ? date : a.sequence.compareTo(b.sequence);
      });
    var total = _bytes;
    for (final entry in oldest) {
      if (total <= _maxBytes) break;
      await _deleteEntry(entry.hash);
      total -= entry.bytes;
    }
  }

  Future<_CacheEntry?> _existing(String key) async {
    final hash = _hash(key);
    final entry = _entries[hash];
    if (entry == null) return null;
    final file = _file(entry);
    if (_expired(entry) ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != entry.bytes) {
      await _deleteEntry(hash);
      await _writeIndex();
      return null;
    }
    return entry;
  }

  Future<Uint8List?> read(String key) => _serialize(() async {
    final entry = await _existing(key);
    if (entry == null) return null;
    return _file(entry).readAsBytes();
  });

  Future<String?> pathFor(String key) => _serialize(() async {
    final entry = await _existing(key);
    return entry == null ? null : _file(entry).path;
  });

  Future<String?> put(
    String key,
    Uint8List bytes, {
    String extension = 'bin',
    Duration? ttl,
    int? expectedGeneration,
  }) {
    final suffix = extension.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
    if (!RegExp(r'^[a-z0-9]{1,10}$').hasMatch(suffix)) {
      throw ArgumentError.value(
        extension,
        'extension',
        'Invalid cache extension',
      );
    }
    // The caller may reuse its receive buffer before queued I/O begins.
    final snapshot = Uint8List.fromList(bytes);
    return _serialize(() async {
      if (expectedGeneration != null && expectedGeneration != _generation) {
        return null;
      }
      final hash = _hash(key);
      if (snapshot.length > _maxBytes ||
          _maxBytes == 0 ||
          (ttl != null && ttl <= Duration.zero)) {
        await _deleteEntry(hash);
        await _writeIndex();
        return null;
      }
      final previous = _entries[hash];
      final filename = '$hash.$suffix';
      final file = File(p.join(_files.path, filename));
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsBytes(snapshot, flush: true);
      // A clear can be requested while the file write was in flight.
      if (expectedGeneration != null && expectedGeneration != _generation) {
        await temporary.delete();
        return null;
      }
      await temporary.rename(file.path);
      if (previous != null && previous.filename != filename) {
        await _deleteEntry(hash);
      }
      final now = _clock().toUtc();
      _entries[hash] = _CacheEntry(
        hash: hash,
        filename: filename,
        bytes: snapshot.length,
        createdAt: now,
        expiresAt: ttl == null ? null : now.add(ttl),
        sequence: _nextSequence++,
      );
      await _evict();
      await _writeIndex();
      if (expectedGeneration != null && expectedGeneration != _generation) {
        return null;
      }
      return _entries.containsKey(hash) ? file.path : null;
    });
  }

  Future<void> remove(String key) => _serialize(() async {
    await _deleteEntry(_hash(key));
    await _writeIndex();
  });

  Future<void> clear() {
    // Invalidate pending network work synchronously, before queued cache I/O.
    _generation++;
    return _serialize(() async {
      for (final hash in _entries.keys.toList()) {
        await _deleteEntry(hash);
      }
      await _removeOrphans();
      await _writeIndex();
    });
  }

  Future<void> setMaxBytes(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'maxBytes', 'Must be non-negative');
    }
    return _serialize(() async {
      _maxBytes = value;
      await _evict();
      await _writeIndex();
    });
  }

  Future<CacheStats> stats() => _serialize(() async {
    await _evict();
    await _writeIndex();
    return CacheStats(
      bytes: _bytes,
      count: _entries.length,
      maxBytes: _maxBytes,
    );
  });
}

class _CacheEntry {
  const _CacheEntry({
    required this.hash,
    required this.filename,
    required this.bytes,
    required this.createdAt,
    required this.sequence,
    this.expiresAt,
  });

  final String hash, filename;
  final int bytes, sequence;
  final DateTime createdAt;
  final DateTime? expiresAt;

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'filename': filename,
    'bytes': bytes,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'sequence': sequence,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
  };

  static _CacheEntry? parse(dynamic value) {
    if (value is! Map ||
        value['hash'] is! String ||
        value['filename'] is! String ||
        value['bytes'] is! int ||
        (value['bytes'] as int) < 0 ||
        value['sequence'] is! int ||
        (value['sequence'] as int) < 0 ||
        value['createdAt'] is! String) {
      return null;
    }
    final createdAt = DateTime.tryParse(value['createdAt'] as String);
    final expiration = value['expiresAt'];
    if (createdAt == null || (expiration != null && expiration is! String)) {
      return null;
    }
    final expiresAt = expiration == null
        ? null
        : DateTime.tryParse(expiration as String);
    if (expiration != null && expiresAt == null) return null;
    return _CacheEntry(
      hash: value['hash'] as String,
      filename: value['filename'] as String,
      bytes: value['bytes'] as int,
      createdAt: createdAt.toUtc(),
      expiresAt: expiresAt?.toUtc(),
      sequence: value['sequence'] as int,
    );
  }
}
