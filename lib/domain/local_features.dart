import 'dart:math';

import 'models.dart';

/// Device-owned state. Old libraries intentionally have no fabricated dates.
class LocalFeatures {
  final Map<String, DateTime> added = {}, lastPlayed = {};
  final Map<String, Map<String, dynamic>> edits = {};
  final Map<String, ListeningBucket> listening = {};
  final Set<String> pinned = {},
      automatic = {},
      blocked = {},
      blockedSongs = {},
      mutedArtists = {};
  final Map<String, int> skips = {}, lyricOffsets = {};

  static LocalFeatures fromJson(Object? raw) {
    final result = LocalFeatures();
    if (raw is! Map) return result;
    void dates(String key, Map<String, DateTime> target) {
      final values = raw[key];
      if (values is Map) {
        for (final entry in values.entries) {
          final date = DateTime.tryParse('${entry.value}');
          if (date != null) target['${entry.key}'] = date;
        }
      }
    }

    dates('added', result.added);
    dates('lastPlayed', result.lastPlayed);
    for (final entry in {
      'pinned': result.pinned,
      'automatic': result.automatic,
      'blocked': result.blocked,
      'blockedSongs': result.blockedSongs,
      'mutedArtists': result.mutedArtists,
    }.entries) {
      final values = raw[entry.key];
      if (values is List) entry.value.addAll(values.whereType<String>());
    }
    for (final entry in {
      'skips': result.skips,
      'lyricOffsets': result.lyricOffsets,
    }.entries) {
      final values = raw[entry.key];
      if (values is Map) {
        for (final value in values.entries) {
          if (value.value is num) {
            entry.value['${value.key}'] = (value.value as num).toInt();
          }
        }
      }
    }
    final edits = raw['edits'];
    if (edits is Map) {
      for (final entry in edits.entries) {
        if (entry.value is Map) {
          result.edits['${entry.key}'] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        }
      }
    }
    final buckets = raw['listening'];
    if (buckets is List) {
      for (final value in buckets.whereType<Map>()) {
        final bucket = ListeningBucket.fromJson(value);
        if (bucket != null) result.listening[bucket.key] = bucket;
      }
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
    'added': added.map((k, v) => MapEntry(k, v.toUtc().toIso8601String())),
    'lastPlayed': lastPlayed.map(
      (k, v) => MapEntry(k, v.toUtc().toIso8601String()),
    ),
    'edits': edits.map((k, v) => MapEntry(k, Map<String, dynamic>.of(v))),
    'listening': listening.values.map((b) => b.toJson()).toList(),
    'pinned': pinned.toList(),
    'automatic': automatic.toList(),
    'blocked': blocked.toList(),
    'blockedSongs': blockedSongs.toList(),
    'mutedArtists': mutedArtists.toList(),
    'skips': Map<String, int>.of(skips),
    'lyricOffsets': Map<String, int>.of(lyricOffsets),
  };

  ListeningBucket bucket(Track track, DateTime now) {
    final day = dayKey(now);
    return listening.putIfAbsent(
      '$day/${track.id}',
      () => ListeningBucket(day, track.id, track.artist),
    );
  }

  static String dayKey(DateTime value) {
    final date = value.toLocal();
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

class ListeningBucket {
  ListeningBucket(
    this.day,
    this.trackId,
    this.artist, {
    this.plays = 0,
    this.milliseconds = 0,
  });
  final String day, trackId, artist;
  int plays, milliseconds;
  String get key => '$day/$trackId';
  Map<String, dynamic> toJson() => {
    'day': day,
    'trackId': trackId,
    'artist': artist,
    'plays': plays,
    'milliseconds': milliseconds,
  };
  static ListeningBucket? fromJson(Map raw) {
    final day = raw['day'], id = raw['trackId'], artist = raw['artist'];
    if (day is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day) ||
        id is! String ||
        artist is! String) {
      return null;
    }
    return ListeningBucket(
      day,
      id,
      artist,
      plays: max(0, (raw['plays'] as num?)?.toInt() ?? 0),
      milliseconds: max(0, (raw['milliseconds'] as num?)?.toInt() ?? 0),
    );
  }
}

class ListeningSummary {
  ListeningSummary(Iterable<ListeningBucket> buckets) {
    for (final bucket in buckets) {
      plays += bucket.plays;
      milliseconds += bucket.milliseconds;
      daily[bucket.day] = (daily[bucket.day] ?? 0) + bucket.milliseconds;
      artists[bucket.artist] =
          (artists[bucket.artist] ?? 0) + bucket.milliseconds;
    }
  }
  int plays = 0, milliseconds = 0;
  final Map<String, int> daily = {}, artists = {};
}

/// Accounts only advancing audio and caps seeks by elapsed monotonic time.
class ListeningClock {
  String? _id;
  int _position = 0, _elapsed = 0;
  bool _active = false;
  int sample(String? id, int position, bool active, int elapsed) {
    if (id == _id && active && _active && position == _position) return 0;
    final wall = elapsed - _elapsed, audio = position - _position;
    final credited =
        id == _id && active && _active && wall > 0 && wall <= 30000 && audio > 0
        ? min(wall, audio)
        : 0;
    _id = id;
    _position = position;
    _elapsed = elapsed;
    _active = active;
    return credited;
  }
}

List<Track> selectSmartTracks({
  required Iterable<Track> tracks,
  required Map<String, dynamic> rule,
  required Set<String> liked,
  required int Function(String) plays,
  required LocalFeatures features,
  required DateTime now,
}) {
  final artist = '${rule['artist'] ?? ''}'.trim().toLowerCase();
  final fromYear = rule['fromYear'] as int?, toYear = rule['toYear'] as int?;
  final days = rule['notPlayedDays'] as int?;
  final addedDays = rule['addedDays'] as int?;
  final result = tracks.where((track) {
    if (rule['liked'] == true && !liked.contains(track.id)) return false;
    if (rule['offline'] == true && !track.offline) return false;
    if (rule['unplayed'] == true && plays(track.id) != 0) return false;
    if (artist.isNotEmpty && !track.artist.toLowerCase().contains(artist)) {
      return false;
    }
    if (fromYear != null && (track.year == null || track.year! < fromYear)) {
      return false;
    }
    if (toYear != null && (track.year == null || track.year! > toYear)) {
      return false;
    }
    if (days != null &&
        features.lastPlayed[track.id] != null &&
        now.difference(features.lastPlayed[track.id]!).inDays < days) {
      return false;
    }
    if (addedDays != null &&
        (features.added[track.id] == null ||
            now.difference(features.added[track.id]!).inDays > addedDays)) {
      return false;
    }
    return true;
  }).toList();
  result.sort((a, b) {
    final order = switch (rule['sort']) {
      'rare' => plays(a.id).compareTo(plays(b.id)),
      'recent' => (features.added[b.id]?.millisecondsSinceEpoch ?? 0).compareTo(
        features.added[a.id]?.millisecondsSinceEpoch ?? 0,
      ),
      _ => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    };
    return order != 0 ? order : a.id.compareTo(b.id);
  });
  return result.take((rule['limit'] as int? ?? 5000).clamp(1, 5000)).toList();
}

/// Queue occurrence keys are retained, including intentional duplicates.
List<int> smartShuffle(
  List<int> slots,
  Track Function(int) track,
  LocalFeatures features,
  Random random, {
  String? previousArtist,
}) {
  final shuffled = List<int>.of(slots)..shuffle(random);
  final groups = <String, List<int>>{};
  double score(int slot) {
    final item = track(slot);
    return (features.skips[item.id] ?? 0).clamp(0, 100) * 1000 +
        (features.lastPlayed[item.id]?.millisecondsSinceEpoch ?? 0) / 1e10;
  }

  for (final slot in shuffled) {
    groups.putIfAbsent(track(slot).artist.toLowerCase(), () => []).add(slot);
  }
  // Artist buckets use a small heap, keeping large libraries O(n log n).
  final heap = <_ShuffleBucket>[];
  bool before(_ShuffleBucket a, _ShuffleBucket b) =>
      score(a.slots[a.index]) < score(b.slots[b.index]);
  void push(_ShuffleBucket value) {
    heap.add(value);
    var i = heap.length - 1;
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (!before(heap[i], heap[parent])) break;
      final swap = heap[i];
      heap[i] = heap[parent];
      heap[parent] = swap;
      i = parent;
    }
  }

  _ShuffleBucket pop() {
    final result = heap.first, tail = heap.removeLast();
    if (heap.isEmpty) return result;
    heap[0] = tail;
    var i = 0;
    while (i * 2 + 1 < heap.length) {
      var child = i * 2 + 1;
      if (child + 1 < heap.length && before(heap[child + 1], heap[child])) {
        child++;
      }
      if (!before(heap[child], heap[i])) break;
      final swap = heap[i];
      heap[i] = heap[child];
      heap[child] = swap;
      i = child;
    }
    return result;
  }

  for (final entry in groups.entries) {
    final rank = {
      for (var i = 0; i < entry.value.length; i++) entry.value[i]: i,
    };
    entry.value.sort((a, b) {
      final order = score(a).compareTo(score(b));
      return order == 0 ? rank[a]!.compareTo(rank[b]!) : order;
    });
    push(_ShuffleBucket(entry.key, entry.value));
  }
  final result = <int>[];
  var previous = previousArtist?.toLowerCase();
  while (heap.isNotEmpty) {
    var bucket = pop();
    if (bucket.artist == previous && heap.isNotEmpty) {
      final alternative = pop();
      push(bucket);
      bucket = alternative;
    }
    result.add(bucket.slots[bucket.index++]);
    previous = bucket.artist;
    if (bucket.index < bucket.slots.length) push(bucket);
  }
  return result;
}

class _ShuffleBucket {
  _ShuffleBucket(this.artist, this.slots);
  final String artist;
  final List<int> slots;
  int index = 0;
}
