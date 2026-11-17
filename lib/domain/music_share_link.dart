import 'models.dart';

enum MusicShareKind { track, album, release }

/// Public torrent identity only: never serialize a user's paths or source URLs
/// (indexer URLs can contain private API keys).
class MusicShareLink {
  MusicShareLink._(this.hash, this.kind, this.indices, this.title);

  final String hash, title;
  final MusicShareKind kind;
  final Set<int> indices;
  static const maxLength = 16000;
  static final _hashPattern = RegExp(r'^[a-fA-F0-9]{40}$');

  static MusicShareLink? fromTracks(
    Iterable<Track> tracks, {
    required MusicShareKind kind,
    required String title,
  }) {
    final items = tracks.toList();
    if (items.isEmpty) return null;
    final hash = items.first.torrentHash;
    if (hash == null || !_hashPattern.hasMatch(hash)) return null;
    if (items.any(
      (t) =>
          t.source != TrackSource.torrent ||
          t.torrentHash?.toLowerCase() != hash.toLowerCase() ||
          t.torrentIndex == null ||
          t.torrentIndex! < 1 ||
          t.torrentIndex! > 1000000,
    )) {
      return null;
    }
    final indices = items.map((t) => t.torrentIndex!).toSet();
    if (kind != MusicShareKind.release && indices.length > 10000) return null;
    if (kind == MusicShareKind.track && indices.length != 1) return null;
    final result = MusicShareLink._(
      hash.toLowerCase(),
      kind,
      Set.unmodifiable(kind == MusicShareKind.release ? <int>{} : indices),
      String.fromCharCodes(
        title.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').runes.take(240),
      ),
    );
    return result.uri.toString().length <= maxLength ? result : null;
  }

  Uri get uri => Uri(
    scheme: 'mumpa',
    host: 'share',
    path: '/v1',
    queryParameters: {
      'hash': hash,
      'kind': kind.name,
      if (indices.isNotEmpty) 'files': _ranges(indices),
      if (title.isNotEmpty) 'title': title,
    },
  );
  String get magnet => 'magnet:?xt=urn:btih:$hash';
  bool selects(Track track) =>
      track.torrentHash?.toLowerCase() == hash &&
      (kind == MusicShareKind.release || indices.contains(track.torrentIndex));

  static bool isMusicLink(String value) =>
      value.trim().toLowerCase().startsWith('mumpa:');

  factory MusicShareLink.parse(String value) {
    Never invalid() =>
        throw const FormatException('Некорректная ссылка Mumpa.');
    if (value.length > maxLength) invalid();
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'mumpa' ||
        uri.host != 'share' ||
        uri.path != '/v1' ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      invalid();
    }
    final params = uri.queryParametersAll;
    if (params.values.any((v) => v.length != 1) ||
        params.keys.any(
          (k) => !{'hash', 'kind', 'files', 'title'}.contains(k),
        )) {
      invalid();
    }
    final hash = uri.queryParameters['hash'] ?? '';
    if (!_hashPattern.hasMatch(hash)) invalid();
    final kind = MusicShareKind.values
        .where((k) => k.name == uri.queryParameters['kind'])
        .firstOrNull;
    if (kind == null) invalid();
    final indices = <int>{};
    final files = uri.queryParameters['files'];
    if (files != null) {
      for (final range in files.split(',')) {
        if (!RegExp(r'^[1-9][0-9]*(?:-[1-9][0-9]*)?$').hasMatch(range)) {
          invalid();
        }
        final parts = range.split('-');
        final start = int.tryParse(parts.first) ?? 0;
        final end = int.tryParse(parts.last) ?? 0;
        if (start < 1 ||
            end < start ||
            end > 1000000 ||
            end - start > 10000 ||
            indices.length + end - start + 1 > 10000) {
          invalid();
        }
        for (var i = start; i <= end; i++) {
          indices.add(i);
        }
      }
    }
    if (kind == MusicShareKind.release ? files != null : indices.isEmpty) {
      invalid();
    }
    if (kind == MusicShareKind.track && indices.length != 1) invalid();
    final title = uri.queryParameters['title'] ?? '';
    if (title.runes.length > 240 || title.contains(RegExp(r'[\x00-\x1f]'))) {
      invalid();
    }
    return MusicShareLink._(
      hash.toLowerCase(),
      kind,
      Set.unmodifiable(indices),
      title,
    );
  }

  static String _ranges(Set<int> indices) {
    final sorted = indices.toList()..sort();
    final ranges = <String>[];
    for (var i = 0; i < sorted.length; i++) {
      final start = sorted[i];
      var end = start;
      while (i + 1 < sorted.length && sorted[i + 1] == end + 1) {
        end = sorted[++i];
      }
      ranges.add(start == end ? '$start' : '$start-$end');
    }
    return ranges.join(',');
  }
}
