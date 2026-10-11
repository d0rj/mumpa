import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/similar_artist.dart';
import 'media_cache.dart';
import 'source_operation.dart';

/// ListenBrainz artist recommendations. Only the public artist MBID is sent.
///
/// The supplied HTTP client belongs to the caller and is never closed here.
/// Network failures propagate so the UI can hide the optional block or retry.
class SimilarArtistsRepository {
  SimilarArtistsRepository({
    required this.cache,
    required this.client,
    this.requestInterval = const Duration(milliseconds: 1100),
    this.requestTimeout = const Duration(seconds: 10),
  });

  final DiskMediaCache cache;
  final http.Client client;
  final Duration requestInterval, requestTimeout;
  final Map<String, _SimilarArtistsLoad> _pending = {};
  Future<void> _tail = Future.value();
  DateTime? _lastRequest;
  bool _disposed = false;

  static const algorithm =
      'session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30';
  static const maxResults = 12;
  static const _maxResponseBytes = 256 * 1024;
  static const _agent = 'Mumpa/1.2.8 (https://github.com/d0rj/mumpa)';
  static final _mbid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  );
  static final _controls = RegExp(r'[\x00-\x1f\x7f]');

  void _check(int generation, SourceOperation operation) {
    operation.check();
    if (_disposed || generation != cache.generation) {
      throw const SourceCancelled();
    }
  }

  Future<List<SimilarArtist>> similarArtists(
    String artistId, {
    SourceOperation? operation,
  }) async {
    operation?.check();
    if (_disposed) throw const SourceCancelled();
    final seed = artistId.trim().toLowerCase();
    if (!_mbid.hasMatch(seed)) {
      throw ArgumentError.value(artistId, 'artistId', 'Invalid artist MBID');
    }
    final generation = cache.generation;
    final pendingKey = '$generation:$seed';
    var load = _pending[pendingKey];
    if (load == null || load.operation.cancelled) {
      load = _SimilarArtistsLoad();
      final current = load;
      _pending[pendingKey] = current;
      current.result = _fetch(seed, generation, current.operation).whenComplete(
        () {
          if (identical(_pending[pendingKey], current)) {
            _pending.remove(pendingKey);
          }
        },
      );
    }
    load.listeners++;
    try {
      final artists = await (operation?.wait(load.result) ?? load.result);
      operation?.check();
      _check(generation, load.operation);
      return artists;
    } finally {
      load.listeners--;
      // One cancelled page must not abort a request still used by another page.
      if (load.listeners == 0) load.operation.cancel();
    }
  }

  Future<List<SimilarArtist>> _fetch(
    String seed,
    int generation,
    SourceOperation operation,
  ) async {
    final key = 'listenbrainz-similar:v1:$algorithm:$seed';
    final saved = await cache.read(key);
    _check(generation, operation);
    if (saved != null) {
      try {
        if (saved.length > _maxResponseBytes) {
          throw const FormatException('Cached recommendations are too large.');
        }
        return _parse(jsonDecode(utf8.decode(saved)), seed);
      } on FormatException {
        await cache.remove(key);
        _check(generation, operation);
      }
    }
    final uri = Uri.https(
      'labs.api.listenbrainz.org',
      '/similar-artists/json',
      {'artist_mbids': seed, 'algorithm': algorithm},
    );
    final bytes = await _schedule(uri, generation, operation);
    _check(generation, operation);
    final artists = _parse(jsonDecode(utf8.decode(bytes)), seed);
    // Store only the bounded, checked public records, not arbitrary API fields.
    final sanitized = Uint8List.fromList(
      utf8.encode(
        jsonEncode([
          for (final artist in artists)
            {
              'artist_mbid': artist.id,
              'name': artist.name,
              'score': artist.score,
              'comment': artist.disambiguation,
              'type': artist.type,
              'reference_mbid': seed,
            },
        ]),
      ),
    );
    _check(generation, operation);
    await cache.put(
      key,
      sanitized,
      extension: 'json',
      ttl: artists.isEmpty ? const Duration(days: 1) : const Duration(days: 7),
      expectedGeneration: generation,
    );
    _check(generation, operation);
    return artists;
  }

  Future<Uint8List> _schedule(
    Uri uri,
    int generation,
    SourceOperation operation,
  ) {
    final result = _tail.then((_) async {
      _check(generation, operation);
      if (_lastRequest != null) {
        final delay =
            requestInterval - DateTime.now().difference(_lastRequest!);
        if (delay > Duration.zero) {
          await operation.wait(Future<void>.delayed(delay));
        }
      }
      _check(generation, operation);
      _lastRequest = DateTime.now();
      return _receive(uri, generation, operation);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Uint8List> _receive(
    Uri uri,
    int generation,
    SourceOperation operation,
  ) async {
    var timedOut = false;
    final deadline = Timer(requestTimeout, () {
      timedOut = true;
      operation.cancel();
    });
    StreamIterator<List<int>>? chunks;
    try {
      final response = await operation.wait(
        client.send(
          http.AbortableRequest(
              'GET',
              uri,
              abortTrigger: operation.whenCancelled,
            )
            ..headers.addAll({
              'User-Agent': _agent,
              'Accept': 'application/json',
            })
            ..followRedirects = false,
        ),
      );
      chunks = StreamIterator(response.stream);
      _check(generation, operation);
      if (response.statusCode != 200) {
        throw HttpException('ListenBrainz: HTTP ${response.statusCode}.');
      }
      if ((response.contentLength ?? 0) > _maxResponseBytes) {
        throw const FormatException('ListenBrainz response is too large.');
      }
      final bytes = BytesBuilder(copy: false);
      while (await operation.wait(chunks.moveNext())) {
        _check(generation, operation);
        bytes.add(chunks.current);
        if (bytes.length > _maxResponseBytes) {
          throw const FormatException('ListenBrainz response is too large.');
        }
      }
      _check(generation, operation);
      return bytes.takeBytes();
    } on SourceCancelled {
      if (timedOut && !_disposed && generation == cache.generation) {
        throw TimeoutException(
          'ListenBrainz request timed out.',
          requestTimeout,
        );
      }
      rethrow;
    } on http.RequestAbortedException {
      if (timedOut && !_disposed && generation == cache.generation) {
        throw TimeoutException(
          'ListenBrainz request timed out.',
          requestTimeout,
        );
      }
      _check(generation, operation);
      rethrow;
    } finally {
      deadline.cancel();
      await chunks?.cancel();
    }
  }

  List<SimilarArtist> _parse(Object? data, String seed) {
    if (data is! List || data.length > 1000) {
      throw const FormatException('Unexpected ListenBrainz response.');
    }
    final byId = <String, SimilarArtist>{};
    for (final item in data) {
      if (item is! Map) continue;
      final id = item['artist_mbid'];
      final reference = item['reference_mbid'];
      final name = item['name'];
      final score = item['score'];
      if (id is! String ||
          reference is! String ||
          name is! String ||
          score is! int ||
          score <= 0) {
        continue;
      }
      final normalizedId = id.trim().toLowerCase();
      final trimmedName = name.trim();
      if (!_mbid.hasMatch(normalizedId) ||
          reference.trim().toLowerCase() != seed ||
          normalizedId == seed ||
          trimmedName.isEmpty ||
          trimmedName.length > 256 ||
          _controls.hasMatch(trimmedName)) {
        continue;
      }
      final artist = SimilarArtist(
        id: normalizedId,
        name: trimmedName,
        score: score,
        disambiguation: _optionalText(item['comment'], 512),
        type: _optionalText(item['type'], 64),
      );
      if (score > (byId[normalizedId]?.score ?? -1)) {
        byId[normalizedId] = artist;
      }
    }
    final artists = byId.values.toList()
      ..sort((a, b) {
        final score = b.score.compareTo(a.score);
        return score != 0
            ? score
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return List<SimilarArtist>.unmodifiable(artists.take(maxResults));
  }

  String _optionalText(Object? value, int maxLength) {
    if (value is! String ||
        value.length > maxLength ||
        _controls.hasMatch(value)) {
      return '';
    }
    return value.trim();
  }

  void dispose() {
    _disposed = true;
    for (final load in _pending.values) {
      load.operation.cancel();
    }
  }
}

class _SimilarArtistsLoad {
  final operation = SourceOperation();
  late final Future<List<SimilarArtist>> result;
  int listeners = 0;
}
