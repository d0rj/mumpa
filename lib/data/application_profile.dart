import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'library_storage.dart';

/// AppData is virtualized when a desktop app inherits an MSIX host identity.
/// USERPROFILE/.mumpa is shared by Explorer, terminals and packaged launchers.
class ApplicationProfile {
  ApplicationProfile._(this.root, this._lock);
  final Directory root;
  final RandomAccessFile _lock;
  bool _closed = false;

  static Directory windowsRoot(String home) {
    if (home.isEmpty || !p.isAbsolute(home)) {
      throw const FileSystemException('Не найден постоянный профиль Windows.');
    }
    return Directory(p.join(home, '.mumpa'));
  }

  static Future<List<Directory>> legacyWindowsRoots(
    String home,
    Directory support,
  ) async {
    final roots = [
      support,
      Directory(
        p.join(home, 'AppData', 'Roaming', 'app.mumpa', 'mumpa', 'Mumpa'),
      ),
    ];
    final packages = Directory(p.join(home, 'AppData', 'Local', 'Packages'));
    if (await packages.exists()) {
      await for (final package in packages.list(followLinks: false)) {
        if (package is! Directory) continue;
        // Inspect only Mumpa's exact relative path, never other app contents.
        final candidate = Directory(
          p.join(
            package.path,
            'LocalCache',
            'Roaming',
            'app.mumpa',
            'mumpa',
            'Mumpa',
          ),
        );
        if (await candidate.exists()) roots.add(candidate);
      }
    }
    return roots;
  }

  static Future<ApplicationProfile> open({
    required String home,
    required List<Directory> legacyRoots,
  }) async {
    final root = windowsRoot(home);
    await root.create(recursive: true);
    final lock = await File(
      p.join(root.path, 'profile.lock'),
    ).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      await lock.close();
      throw const FileSystemException(
        'Mumpa уже использует эту медиатеку. Открой запущенное приложение или заверши его перед обновлением.',
      );
    }
    final profile = ApplicationProfile._(root, lock);
    try {
      // Once committed, never re-import old likes: intentional removals must
      // survive future launches. LibraryStorage handles recovery/corruption.
      if (!await File(p.join(root.path, 'profile-migration.json')).exists() &&
          !await File(p.join(root.path, 'library.json')).exists() &&
          !await File(p.join(root.path, 'library.json.bak')).exists() &&
          !await File(p.join(root.path, 'library.json.tmp')).exists()) {
        await _migrate(root, legacyRoots);
      }
      return profile;
    } catch (_) {
      await profile.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _lock.unlock();
    } finally {
      await _lock.close();
    }
  }

  static Future<void> _migrate(
    Directory root,
    List<Directory> candidates,
  ) async {
    final sources = <_LegacyProfile>[];
    final seen = <String>{};
    var unreadable = false;
    for (final candidate in candidates) {
      if (!await candidate.exists()) continue;
      final actual = Directory(await candidate.resolveSymbolicLinks());
      if (p.equals(actual.path, root.path) ||
          !seen.add(p.normalize(actual.path).toLowerCase())) {
        continue;
      }
      final store = LibraryStorage(actual);
      final json = await store.load();
      if (json == null) {
        unreadable |= store.warning != null;
        continue;
      }
      sources.add(_LegacyProfile(actual, candidate, json));
    }
    if (sources.isEmpty) {
      if (unreadable) {
        throw const FileSystemException(
          'Старая медиатека найдена, но не читается. Исходные файлы сохранены; создание пустого профиля остановлено.',
        );
      }
      return;
    }
    sources.sort((a, b) => b.score.compareTo(a.score));
    final tracks = <String, dynamic>{}, playlists = <String, dynamic>{};
    final settings = <String, dynamic>{};
    final sets = {
      for (final name in [
        'liked',
        'likedPlaylists',
        'recent',
        'retainedTrackIds',
        'trackMatchExcluded',
        'preferredTrackVariants',
      ])
        name: <String>{},
    };
    final albums = <String, List<String>>{};
    // Richest profile owns conflicting metadata/settings, but all personal
    // additions across the formerly separated profiles are retained once.
    for (final source in sources.reversed) {
      settings.addAll(
        Map<String, dynamic>.from(source.json['settings'] as Map? ?? {}),
      );
      for (final name in sets.keys) {
        sets[name]!.addAll(List<String>.from(source.json[name] as List? ?? []));
      }
      for (final ids in source.json['likedAlbums'] as List? ?? []) {
        final album = List<String>.from(ids as List);
        final sorted = List<String>.of(album)..sort();
        albums[jsonEncode(sorted)] = album;
      }
      for (final raw in source.json['playlists'] as List? ?? []) {
        final item = Map<String, dynamic>.from(raw as Map);
        final old = playlists[item['id']] as Map?;
        if (old != null) {
          item['trackIds'] = {
            ...List<String>.from(old['trackIds'] as List),
            ...List<String>.from(item['trackIds'] as List),
          }.toList();
        }
        playlists[item['id'] as String] = item;
      }
      for (final raw in source.json['tracks'] as List) {
        final item = Map<String, dynamic>.from(raw as Map);
        for (final field in ['cachedPath', 'localPath', 'artPath']) {
          final value = item[field];
          if (value is String) {
            item[field] = await _importPath(root, source, value);
          }
        }
        tracks[item['id'] as String] = item;
      }
    }
    // Metainfo and account state are durable; executable runtimes, engine state
    // and regenerable media caches are intentionally not copied.
    for (final source in sources) {
      for (final name in [
        'torrents',
        'artwork',
        'demo',
        'jackett',
        'catalog',
      ]) {
        await _copyTree(
          Directory(p.join(source.root.path, name)),
          Directory(p.join(root.path, name)),
        );
      }
    }
    final imported = <String, dynamic>{
      ...sources.first.json,
      'tracks': tracks.values.toList(),
      'playlists': playlists.values.toList(),
      'settings': settings,
      for (final entry in sets.entries) entry.key: entry.value.toList(),
      'likedAlbums': albums.values.toList(),
    };
    final contents = jsonEncode(imported);
    LibraryStorage.decode(contents);
    final backups = Directory(p.join(root.path, 'backups', 'imported'));
    await backups.create(recursive: true);
    for (final source in sources) {
      final name = sha256
          .convert(utf8.encode(source.root.path))
          .toString()
          .substring(0, 16);
      await File(
        p.join(backups.path, '$name.json'),
      ).writeAsString(jsonEncode(source.json), flush: true);
    }
    // Commit JSON last. On interruption the old profiles are untouched, and
    // already copied media is hash-checked/reused on retry.
    await File(
      p.join(root.path, 'library.json.bak'),
    ).writeAsString(contents, flush: true);
    final temporary = File(p.join(root.path, 'library.json.tmp'));
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(p.join(root.path, 'library.json'));
    await File(p.join(root.path, 'profile-migration.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
        'sources': sources.map((s) => s.root.path).toList(),
        'tracks': tracks.length,
        'favorites': sets['liked']!.length,
      }),
      flush: true,
    );
  }

  static Future<String> _importPath(
    Directory target,
    _LegacyProfile source,
    String value,
  ) async {
    final aliases = {
      source.root.path, source.logical.path,
      // Serialized paths from a virtualized process still spell real Roaming.
      ...source.aliases,
    };
    for (final alias in aliases) {
      if (!p.isWithin(alias, value)) continue;
      final relative = p.relative(value, from: alias);
      final file = File(p.join(source.root.path, relative));
      if (!await file.exists()) continue;
      if (!{
        'downloads',
        'artwork',
        'demo',
        'torrents',
      }.contains(p.split(relative).first)) {
        return file.path;
      }
      var destination = File(p.join(target.path, relative));
      if (await destination.exists() && !await _same(file, destination)) {
        final identity = sha256
            .convert(utf8.encode(source.root.path))
            .toString()
            .substring(0, 16);
        destination = File(p.join(target.path, 'imports', identity, relative));
      }
      await _copyFile(file, destination);
      return destination.path;
    }
    return value; // User-selected music outside Mumpa stays in its own folder.
  }

  static Future<bool> _same(File a, File b) async =>
      await a.length() == await b.length() &&
      (await sha256.bind(a.openRead()).first).toString() ==
          (await sha256.bind(b.openRead()).first).toString();

  static Future<void> _copyFile(File source, File destination) async {
    if (await destination.exists()) {
      if (!await _same(source, destination)) {
        throw FileSystemException(
          'Конфликт файлов при переносе медиатеки; исходники сохранены.',
          destination.path,
        );
      }
      return;
    }
    await destination.parent.create(recursive: true);
    final staged = await source.copy('${destination.path}.importing');
    if (!await _same(source, staged)) {
      throw const FileSystemException(
        'Не удалось проверить копию файла медиатеки.',
      );
    }
    await staged.rename(destination.path);
  }

  static Future<void> _copyTree(Directory source, Directory target) async {
    if (!await source.exists()) return;
    await for (final item in source.list(followLinks: false)) {
      final destination = p.join(target.path, p.basename(item.path));
      if (item is Directory) {
        await _copyTree(item, Directory(destination));
      } else if (item is File && !await File(destination).exists()) {
        await _copyFile(item, File(destination));
      }
    }
  }
}

class _LegacyProfile {
  _LegacyProfile(this.root, this.logical, this.json);
  final Directory root, logical;
  final Map<String, dynamic> json;
  int get score =>
      (json['liked'] as List? ?? []).length * 1000000 +
      (json['tracks'] as List).length;
  Iterable<String> get aliases sync* {
    final marker =
        '${p.separator}AppData${p.separator}Local${p.separator}Packages${p.separator}';
    final virtualized = RegExp(RegExp.escape(marker), caseSensitive: false);
    // Windows temp/launch hosts can use an 8.3 path while resolving the same
    // profile returns its long name. Preserve Roaming aliases for both forms.
    for (final path in {p.normalize(root.path), p.normalize(logical.path)}) {
      final match = virtualized.firstMatch(path);
      if (match == null) continue;
      yield p.join(
        path.substring(0, match.start),
        'AppData',
        'Roaming',
        'app.mumpa',
        'mumpa',
        'Mumpa',
      );
    }
  }
}
