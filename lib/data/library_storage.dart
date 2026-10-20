import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/models.dart';

/// Personal data is never treated as disposable cache. Validate a whole
/// snapshot before publishing it, and keep recovery files outside build trees.
class LibraryStorage {
  LibraryStorage(this.root);
  final Directory root;
  bool _primaryValid = false, _unrecoverable = false;
  String? _recoveryContents;
  String? warning;
  File get primary => File(p.join(root.path, 'library.json'));

  static Map<String, dynamic> decode(String contents) {
    final json = jsonDecode(contents) as Map<String, dynamic>;
    if (json['tracks'] is! List) throw const FormatException('Missing tracks');
    for (final track in json['tracks'] as List) {
      Track.fromJson(Map<String, dynamic>.from(track as Map));
    }
    for (final playlist in json['playlists'] as List? ?? []) {
      MusicPlaylist.fromJson(Map<String, dynamic>.from(playlist as Map));
    }
    for (final key in [
      'liked',
      'likedPlaylists',
      'recent',
      'retainedTrackIds',
      'trackMatchExcluded',
      'preferredTrackVariants',
    ]) {
      List<String>.from(json[key] as List? ?? []);
    }
    for (final album in json['likedAlbums'] as List? ?? []) {
      List<String>.from(album as List);
    }
    Map<String, dynamic>.from(json['settings'] as Map? ?? {});
    for (final key in ['trackPlayCounts', 'playlistPlayCounts']) {
      final counts = Map<String, int>.from(json[key] as Map? ?? {});
      if (counts.values.any((count) => count < 0)) {
        throw FormatException('Invalid $key');
      }
    }
    return json;
  }

  Future<Map<String, dynamic>?> load() async {
    await root.create(recursive: true);
    var found = false;
    final backups = Directory(p.join(root.path, 'backups'));
    final daily = await backups.exists()
        ? (await backups
                .list()
                .where(
                  (entry) =>
                      entry is File &&
                      RegExp(
                        r'library-\d{4}-\d{2}-\d{2}\.json$',
                      ).hasMatch(p.basename(entry.path)),
                )
                .toList()
            ..sort((a, b) => b.path.compareTo(a.path)))
        : <FileSystemEntity>[];
    for (final file in [
      primary,
      File('${primary.path}.tmp'),
      File('${primary.path}.bak'),
      ...daily.cast<File>(),
    ]) {
      if (!await file.exists()) continue;
      found = true;
      try {
        final contents = await file.readAsString();
        final json = decode(contents);
        _primaryValid = file.path == primary.path;
        _recoveryContents = _primaryValid ? null : contents;
        if (!_primaryValid) {
          warning =
              'Библиотека восстановлена из резервной копии вместе с настройками.';
        }
        return json;
      } catch (_) {
        // Try independent generations; never publish a partially decoded state.
      }
    }
    _unrecoverable = found;
    if (found) {
      warning =
          'Не удалось прочитать библиотеку. Файлы сохранены; запись заблокирована, чтобы не потерять избранное. Папка данных доступна в настройках.';
    }
    return null;
  }

  void checkWritable() {
    if (_unrecoverable) {
      throw const FileSystemException(
        'Библиотека повреждена. Сохранение остановлено для защиты исходных данных.',
      );
    }
  }

  Future<void> save(String contents) async {
    checkWritable();
    final temporary = File('${primary.path}.tmp');
    if (_recoveryContents case final String recovered) {
      await File('${primary.path}.bak').writeAsString(recovered, flush: true);
    }
    // Protect the last known good generation when recovery used .bak or .tmp.
    if (!_primaryValid && await primary.exists()) {
      await primary.copy(
        p.join(
          root.path,
          'library-unreadable-${DateTime.now().microsecondsSinceEpoch}.json',
        ),
      );
    }
    if (_primaryValid && await primary.exists()) {
      await primary.copy('${primary.path}.bak');
    }
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(primary.path);
    _primaryValid = true;
    _recoveryContents = null;
    final backups = Directory(p.join(root.path, 'backups'));
    await backups.create(recursive: true);
    final day = DateTime.now().toIso8601String().substring(0, 10);
    final daily = File(p.join(backups.path, 'library-$day.json'));
    final newDay = !await daily.exists();
    final staged = await primary.copy('${daily.path}.tmp');
    await staged.rename(daily.path);
    if (newDay) {
      final generations =
          await backups
                .list()
                .where(
                  (entry) =>
                      entry is File &&
                      RegExp(
                        r'^library-\d{4}-\d{2}-\d{2}\.json$',
                      ).hasMatch(p.basename(entry.path)),
                )
                .toList()
            ..sort((a, b) => b.path.compareTo(a.path));
      for (final old in generations.skip(7)) {
        await old.delete();
      }
    }
  }
}
