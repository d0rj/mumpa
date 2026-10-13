import 'dart:isolate';
import 'dart:math' as math;

import 'models.dart';
import 'music_metadata.dart';

final _identities = Expando<_TrackIdentity>('track-matching-identity');
final _annotations = RegExp(r'\(([^()]*)\)|\[([^\[\]]*)\]');
final _safeAnnotation = RegExp(
  r'^(?:(?:clean|explicit|uncensored|censored|dirty|unedited)(?: version| edit)?|'
  r'без цензуры|цензурная версия|нецензурная версия|'
  r'remaster(?:ed)?(?: (?:version|edition))?(?: \d{4})?|\d{4} remaster(?:ed)?|'
  r'(?:mp3|flac|alac|aac|ogg|opus|wav|ape|lossless|lossy)(?: \d+ ?(?:kbps|kbit s))?|'
  r'\d+ ?(?:kbps|kbit s))$',
);
final _safeSuffix = RegExp(
  r'\s+[–—-]\s+((?:clean|explicit|uncensored|censored|dirty|unedited)(?: version| edit)?|'
  r'без цензуры|цензурная версия|нецензурная версия|'
  r'remaster(?:ed)?(?: \d{4})?)$',
  caseSensitive: false,
);
final _performanceContext = RegExp(
  r'\b(live|concert|acoustic|unplugged|instrumental|karaoke|demo|rehearsal|'
  r'remix|mix|radio edit|extended|re recorded|rerecorded)\b|'
  r'концерт|акустич|инструментал|ремикс|перезапис',
);
final _censorLabel = RegExp(
  r'\b(clean|explicit|uncensored|censored|dirty|unedited)\b|цензур',
);
final _genericTitles = RegExp(
  r'^(?:intro|outro|интро|аутро|вступление|заключение|skit|скит|interlude|интерлюдия|интермедия)(?: \d+)?$',
);
const _unknownArtists = {
  '',
  'unknown',
  'unknown artist',
  'неизвестен',
  'неизвестный',
  'неизвестный исполнитель',
  'без исполнителя',
  'various artists',
  'va',
  'v a',
  'сборник',
};

class _TrackIdentity {
  const _TrackIdentity(this.key, this.censorLabel);
  final String key;
  final bool censorLabel;
}

_TrackIdentity _identity(Track track) {
  final artist = normalizeMusicName(track.artist);
  var title = track.title.trim();
  // A filename can repeat its artist. Only remove an explicitly delimited,
  // exact artist prefix, never arbitrary words or a numbered song title.
  final prefix = RegExp(r'^(.+?)\s+[–—-]\s+(.+)$').firstMatch(title);
  if (prefix != null && normalizeMusicName(prefix[1]!) == artist) {
    title = prefix[2]!;
  }
  title = title
      .replaceAllMapped(_annotations, (match) {
        final label = normalizeMusicName(match[1] ?? match[2]!);
        return _safeAnnotation.hasMatch(label) ? ' ' : match[0]!;
      })
      .replaceFirst(_safeSuffix, '');
  title = normalizeMusicName(title);
  if (_unknownArtists.contains(artist) ||
      title.isEmpty ||
      RegExp(
        r'^(?:(?:track|трек|audio|untitled|без названия)\s*)?\d*$',
      ).hasMatch(title)) {
    return _TrackIdentity('file:${track.id}', false);
  }
  // Some collections omit "Live" etc. from individual filenames. Distinguish
  // those albums, including different concerts, even with unknown durations.
  final album = normalizeMusicName(track.album);
  final folder = normalizeMusicName(track.torrentAlbumPath ?? '');
  final performance = _performanceContext.hasMatch(album)
      ? album
      : _performanceContext.hasMatch(folder)
      ? folder
      : '';
  // "Intro" and "Outro" commonly name different songs on each album. A
  // same-named collection track needs the same album/disc as extra evidence.
  final context = _genericTitles.hasMatch(title)
      ? '$performance\u0000album:$album\u0000disc:${track.disc}'
      : performance;
  return _TrackIdentity(
    '$artist\u0000$title\u0000$context',
    _censorLabel.hasMatch(
      normalizeMusicName(
        '${track.title} ${track.album} ${track.torrentAlbumPath ?? ''} ${track.torrentPath ?? track.localPath ?? ''}',
      ),
    ),
  );
}

/// Normalize new metadata outside the UI isolate before publishing a revision.
Future<void> prepareTrackMatching(List<Track> tracks) async {
  final missing = tracks.where((track) => _identities[track] == null).toList();
  if (missing.isEmpty) return;
  final values = missing.length < 256
      ? missing.map(_identity).toList()
      : await Isolate.run(() => missing.map(_identity).toList());
  for (var i = 0; i < missing.length; i++) {
    _identities[missing[i]] = values[i];
  }
}

class TrackMatchGroup {
  TrackMatchGroup(Iterable<Track> tracks)
    : variants = List.unmodifiable(tracks),
      ids = Set.unmodifiable(tracks.map((track) => track.id));
  final List<Track> variants;
  final Set<String> ids;
  bool get multiple => variants.length > 1;
}

/// One row retains its original collection membership separately from the
/// playable version, which can belong to another already known collection.
class MatchedTrack {
  const MatchedTrack({
    required this.group,
    required this.members,
    required this.preferred,
  });
  final TrackMatchGroup group;
  final List<Track> members;
  final Track preferred;
  Track get anchor => members.first;
}

class TrackMatchIndex {
  TrackMatchIndex(
    List<Track> tracks, {
    Set<String> excluded = const {},
    Set<String> preferred = const {},
    Map<String, String> sourceDescriptions = const {},
  }) : _tracksById = {for (final track in tracks) track.id: track} {
    final buckets = <String, List<Track>>{};
    final censoredSources = sourceDescriptions.map(
      (hash, description) => MapEntry(
        hash,
        _censorLabel.hasMatch(normalizeMusicName(description)),
      ),
    );
    final censorIds = <String>{};
    for (final track in tracks) {
      final identity = _identities[track] ??= _identity(track);
      if (identity.censorLabel || censoredSources[track.torrentHash] == true) {
        censorIds.add(track.id);
      }
      final key = excluded.contains(track.id)
          ? 'file:${track.id}'
          : identity.key;
      buckets.putIfAbsent(key, () => []).add(track);
    }
    for (final bucket in buckets.values) {
      // Sorting known durations makes the partition independent of import
      // order. Missing lengths join only an unambiguous single partition.
      final known = bucket.where((track) => track.durationMs > 0).toList()
        ..sort((a, b) {
          final length = a.durationMs.compareTo(b.durationMs);
          return length != 0 ? length : a.id.compareTo(b.id);
        });
      final lengths = <_DurationPartition>[];
      for (final track in known) {
        final last = lengths.lastOrNull;
        final censored = censorIds.contains(track.id);
        if (last != null && last.accepts(track.durationMs, censored)) {
          last.add(track, censored);
        } else {
          lengths.add(_DurationPartition()..add(track, censored));
        }
      }
      final partitions = lengths.map((partition) => partition.tracks).toList();
      final unknown = bucket.where((track) => track.durationMs <= 0).toList();
      if (partitions.length <= 1) {
        if (partitions.isEmpty) partitions.add([]);
        partitions.single.addAll(unknown);
      } else {
        // An unknown-length file must not bridge e.g. 3- and 6-minute versions.
        partitions.addAll(unknown.map((track) => [track]));
      }
      for (final partition in partitions.where((items) => items.isNotEmpty)) {
        final group = TrackMatchGroup(partition);
        for (final track in partition) {
          _byId[track.id] = group;
        }
      }
    }
    // Preferences are persisted oldest first. The most recent choice wins if
    // metadata enrichment later joins two formerly separate groups.
    for (final id in preferred) {
      final group = _byId[id];
      if (group != null) _defaults[group] = _tracksById[id]!;
    }
  }

  final _byId = <String, TrackMatchGroup>{};
  final Map<String, Track> _tracksById;
  final _defaults = <TrackMatchGroup, Track>{};
  final _rows = Expando<List<MatchedTrack>>('matched-track-rows');
  TrackMatchGroup groupFor(Track track) =>
      _byId[track.id] ?? TrackMatchGroup([track]);

  List<MatchedTrack> rowsFor(List<Track> tracks) {
    final cached = _rows[tracks];
    if (cached != null) return cached;
    final members = <TrackMatchGroup, List<Track>>{};
    for (final track in tracks) {
      members
          .putIfAbsent(groupFor(track), () => [])
          .add(_tracksById[track.id] ?? track);
    }
    final rows = List<MatchedTrack>.unmodifiable([
      for (final entry in members.entries)
        MatchedTrack(
          group: entry.key,
          members: List.unmodifiable(entry.value),
          preferred:
              (_defaults[entry.key]?.offline == true
                  ? _defaults[entry.key]
                  : null) ??
              entry.value.where((track) => track.offline).firstOrNull ??
              entry.key.variants.where((track) => track.offline).firstOrNull ??
              _defaults[entry.key] ??
              entry.value.first,
        ),
    ]);
    return _rows[tracks] = rows;
  }
}

class _DurationPartition {
  final tracks = <Track>[];
  double _ordinaryCeiling = double.infinity, _censoredCeiling = double.infinity;
  bool accepts(int duration, bool censored) =>
      duration <= (censored ? _censoredCeiling : _ordinaryCeiling);
  void add(Track track, bool censored) {
    tracks.add(track);
    final duration = track.durationMs;
    double ceiling(bool censor) =>
        duration +
        (censor
                ? math.max(8000, math.min(30000, duration * .10))
                : math.max(5000, math.min(15000, duration * .05)))
            .toDouble();
    // Known lengths arrive ascending. Intersect every previous file's allowed
    // upper bound in O(1), retaining the all-pairs rule without quadratic work.
    _ordinaryCeiling = math.min(_ordinaryCeiling, ceiling(censored));
    _censoredCeiling = math.min(_censoredCeiling, ceiling(true));
  }
}

/// Container extensions do not prove a codec (M4A can contain AAC or ALAC).
String trackFormatDescription(Track track) {
  final format = track.format;
  if (const {'FLAC', 'ALAC', 'WAV', 'AIFF', 'AIF', 'APE'}.contains(format)) {
    return '$format · lossless';
  }
  if (const {'MP3', 'AAC', 'OPUS'}.contains(format)) {
    return '$format · lossy';
  }
  return format.isEmpty ? 'Формат не указан' : '$format · кодек не указан';
}
