import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'bounded_http.dart';
import 'source_operation.dart';
import '../domain/lyrics.dart';
import '../domain/models.dart';

class LyricsRepository {
  LyricsRepository(this.root, {http.Client? client})
    : _client = client ?? http.Client();
  final Directory root;
  final http.Client _client;
  final _lifetime = SourceOperation();
  Future<void> _writeTail = Future.value();
  final Map<String, int> _edits = {};
  static const maxBytes = 1024 * 1024;
  static Future<void> _requestTail = Future.value();
  static DateTime _nextRequest = DateTime.fromMillisecondsSinceEpoch(0),
      _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
  File _cache(Track track) =>
      File(p.join(root.path, 'lyrics', '${stableId(track.id)}.json'));
  Future<Lyrics> load(
    Track track, {
    bool remote = false,
    bool force = false,
  }) async {
    _lifetime.check();
    final edit = _edits[track.id] ?? 0;
    final cache = _cache(track);
    Map? saved;
    if (await cache.exists() && await cache.length() <= maxBytes) {
      try {
        saved = jsonDecode(await cache.readAsString()) as Map;
      } catch (_) {}
    }
    if (saved?['user'] == true && saved?['text'] is String) {
      return Lyrics.parse(saved!['text'] as String);
    }
    final local = track.localPath ?? track.cachedPath;
    if (local != null) {
      final sidecar = File(p.setExtension(local, '.lrc'));
      if (await sidecar.exists() && await sidecar.length() <= maxBytes) {
        return Lyrics.parse(await sidecar.readAsString());
      }
    }
    if (saved != null) {
      try {
        final time = DateTime.tryParse('${saved['time']}');
        if (saved['user'] == true ||
            !force &&
                time != null &&
                DateTime.now().difference(time).inHours <
                    (saved['text'] == '' ? 24 : 168)) {
          if (saved['text'] != '' || !remote) {
            return Lyrics.parse(saved['text'] as String);
          }
          if (!force) return Lyrics.parse(track.lyrics ?? '');
        }
      } catch (_) {
        /* A damaged cache is replaceable. */
      }
    }
    if (track.lyrics?.trim().isNotEmpty == true && !force) {
      return Lyrics.parse(track.lyrics!);
    }
    if (!remote) return Lyrics.parse(track.lyrics ?? '');
    final request = _requestTail.then((_) async {
      _lifetime.check();
      if (DateTime.now().isBefore(_retryAfter)) {
        throw const HttpException('Сервис текстов занят. Повтори поиск позже.');
      }
      final delay = _nextRequest.difference(DateTime.now());
      if (!delay.isNegative) await _lifetime.wait(Future<void>.delayed(delay));
      _lifetime.check();
      try {
        return await _lookup(track, edit);
      } finally {
        _nextRequest = DateTime.now().add(const Duration(milliseconds: 350));
      }
    });
    _requestTail = request.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return _lifetime.wait(request);
  }

  Future<Lyrics> _lookup(Track track, int edit) async {
    final uri = Uri.https('lrclib.net', '/api/get', {
      'track_name': track.title,
      'artist_name': track.artist,
      'album_name': track.album,
      if (track.durationMs > 0) 'duration': '${track.durationMs / 1000}',
    });
    final response = await getBounded(
      _client,
      uri,
      maxBytes: maxBytes,
      timeout: const Duration(seconds: 15),
      operation: _lifetime,
      headers: {'User-Agent': 'Mumpa/1.3.0 (https://github.com/d0rj/mumpa)'},
    );
    if (response.statusCode == 429) {
      final retry = response.headers['retry-after'];
      _retryAfter = DateTime.now().add(
        Duration(seconds: int.tryParse(retry ?? '') ?? 60),
      );
      if (retry != null && int.tryParse(retry) == null) {
        try {
          _retryAfter = HttpDate.parse(retry);
        } catch (_) {}
      }
      throw const HttpException('Сервис текстов занят. Повтори поиск позже.');
    }
    if (response.statusCode != 200 && response.statusCode != 404) {
      throw const HttpException('Не удалось получить текст песни.');
    }
    var text = '';
    if (response.statusCode == 200) {
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      text = (json['syncedLyrics'] as String?)?.trim().isNotEmpty == true
          ? json['syncedLyrics'] as String
          : json['plainLyrics'] as String? ?? '';
    }
    await _save(track, text, edit: edit);
    if ((_edits[track.id] ?? 0) != edit) return load(track);
    return Lyrics.parse(text);
  }

  Future<void> save(Track track, String text, {bool user = false}) {
    if (user) _edits[track.id] = (_edits[track.id] ?? 0) + 1;
    return _save(track, text, user: user);
  }

  Future<void> _save(Track track, String text, {bool user = false, int? edit}) {
    final result = _writeTail.then((_) async {
      _lifetime.check();
      if (edit != null && (_edits[track.id] ?? 0) != edit) return;
      if (utf8.encode(text).length > maxBytes) {
        throw const FormatException('Текст песни слишком большой.');
      }
      final file = _cache(track);
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          'text': text,
          'user': user,
          'time': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      await temp.rename(file.path);
    });
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void close() {
    _lifetime.cancel();
    _client.close();
  }
}
