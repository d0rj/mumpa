import 'dart:io';
import 'package:path/path.dart' as p;
import '../domain/models.dart';
import 'library_repository.dart';

class PlaylistFiles {
  static const maxBytes = 4 * 1024 * 1024;
  static List<String> parse(String text, {String? baseDirectory}) {
    final result = <String>[];
    for (var line in text.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'))) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('file:')) {
        try {
          line = Uri.parse(line).toFilePath(windows: Platform.isWindows);
        } catch (_) {
          continue;
        }
      } else if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(line) ||
          line.startsWith('magnet:')) {
        continue;
      }
      if (!isAudioPath(line) || line.contains('\u0000')) continue;
      if (!p.isAbsolute(line) && baseDirectory != null) {
        line = p.join(baseDirectory, line);
      }
      result.add(p.normalize(line));
      if (result.length > 10000) {
        throw const FormatException('В плейлисте больше 10000 треков.');
      }
    }
    return result;
  }

  static String encode(
    List<Track> tracks,
    String? Function(Track) pathFor, {
    String? baseDirectory,
  }) {
    final lines = <String>['#EXTM3U'];
    for (final track in tracks) {
      var path = pathFor(track);
      if (path == null || path.contains('\n') || path.contains('\r')) continue;
      if (baseDirectory != null && p.isWithin(baseDirectory, path)) {
        path = p.relative(path, from: baseDirectory);
      }
      final title = '${track.artist} - ${track.title}'.replaceAll(
        RegExp(r'[\r\n]'),
        ' ',
      );
      lines.add('#EXTINF:${track.durationMs ~/ 1000},$title');
      lines.add(path);
    }
    return '${lines.join('\n')}\n';
  }

  static Future<MusicPlaylist> import(
    LibraryRepository library,
    String text,
    String name, {
    String? baseDirectory,
    bool copy = false,
  }) async {
    final ids = <String>[];
    String pathKey(String value) => Platform.isWindows
        ? p.normalize(p.absolute(value)).toLowerCase()
        : p.normalize(p.absolute(value));
    String fileName(String value) =>
        p.posix.basename(value.replaceAll('\\', '/'));
    final paths = parse(text, baseDirectory: baseDirectory);
    final indexed = <String, Track>{
      for (final track in library.tracks)
        for (final path in [
          track.localPath,
          track.cachedPath,
        ].whereType<String>())
          pathKey(path): track,
    };
    final newPaths = <String>{};
    for (final path in paths) {
      if (!indexed.containsKey(pathKey(path)) &&
          p.isAbsolute(path) &&
          await File(path).exists()) {
        newPaths.add(path);
      }
    }
    if (newPaths.isNotEmpty) {
      final sorted = newPaths.toList()..sort();
      final imported = await library.importPaths(sorted, copy: copy);
      for (var i = 0; i < imported.length; i++) {
        indexed[pathKey(sorted[i])] = imported[i];
      }
    }
    final names = <String, Set<Track>>{};
    for (final entry in indexed.entries) {
      names.putIfAbsent(fileName(entry.key), () => {}).add(entry.value);
    }
    for (final path in paths) {
      final known = indexed[pathKey(path)];
      if (known != null && await File(path).exists()) {
        ids.add(known.id);
        continue;
      }
      final matches =
          names[Platform.isWindows
              ? fileName(path).toLowerCase()
              : fileName(path)] ??
          {};
      if (matches.length == 1 &&
          await library.localPathFor(matches.single) != null) {
        ids.add(matches.single.id);
      }
    }
    if (ids.isEmpty) {
      throw const FormatException(
        'Доступные локальные треки не найдены. Сначала добавь музыку на это устройство.',
      );
    }
    final list = await library.createPlaylist(name);
    await library.addToPlaylist(list.id, ids);
    return library.playlistById(list.id)!;
  }
}
