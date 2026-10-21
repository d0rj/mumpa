import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../domain/lyrics.dart';
import '../domain/models.dart';

class LyricsRepository {
  LyricsRepository(this.root, {http.Client? client})
    : _client = client ?? http.Client();
  final Directory root;
  final http.Client _client;
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
      if (DateTime.now().isBefore(_retryAfter)) {
        throw const HttpException('Сервис текстов занят. Повтори поиск позже.');
      }
      final delay = _nextRequest.difference(DateTime.now());
      if (!delay.isNegative) await Future<void>.delayed(delay);
      try {
        return await _lookup(track);
      } finally {
        _nextRequest = DateTime.now().add(const Duration(milliseconds: 350));
      }
    });
    _requestTail = request.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return request;
  }

  Future<Lyrics> _lookup(Track track) async {
    final uri = Uri.https('lrclib.net', '/api/get', {
      'track_name': track.title,
      'artist_name': track.artist,
      'album_name': track.album,
      if (track.durationMs > 0) 'duration': '${track.durationMs / 1000}',
    });
    final response = await _client
        .send(
          http.Request('GET', uri)
            ..headers['User-Agent'] =
                'Mumpa/1.3.0 (https://github.com/d0rj/mumpa)',
        )
        .timeout(const Duration(seconds: 15));
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
      await response.stream
          .take(1)
          .drain<void>()
          .timeout(const Duration(seconds: 15));
      throw const HttpException('Сервис текстов занят. Повтори поиск позже.');
    }
    if (response.statusCode != 200 && response.statusCode != 404) {
      await response.stream.drain<void>();
      throw const HttpException('Не удалось получить текст песни.');
    }
    final data = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      data.addAll(chunk);
      if (data.length > maxBytes) {
        throw const FormatException('Текст песни слишком большой.');
      }
    }
    var text = '';
    if (response.statusCode == 200) {
      final json = jsonDecode(utf8.decode(data)) as Map;
      text = (json['syncedLyrics'] as String?)?.trim().isNotEmpty == true
          ? json['syncedLyrics'] as String
          : json['plainLyrics'] as String? ?? '';
    }
    await save(track, text);
    return Lyrics.parse(text);
  }

  Future<void> save(Track track, String text, {bool user = false}) async {
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
  }

  void close() => _client.close();
}
