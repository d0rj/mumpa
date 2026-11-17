import 'dart:math' as math;

import 'catalog_identity.dart';
import 'models.dart';

final _guestCredit = RegExp(
  r'\s*[\[(](?:feat\.?|ft\.?|featuring|with)\s+[^\])]+[\])]',
  caseSensitive: false,
);
final _versionWords = RegExp(
  r'\b(live|concert|acoustic|unplugged|instrumental|karaoke|demo|remix|mix|'
  r'radio edit|extended|re recorded|rerecorded|remaster\w*|clean|explicit|'
  r'censored|uncensored)\b|концерт|акустич|ремикс|инструментал|перезапис|цензур',
);

String catalogTitle(String title, [String artist = '']) {
  final prefix = RegExp(r'^(.+?)\s+[–—-]\s+(.+)$').firstMatch(title);
  if (prefix != null && catalogText(prefix[1]!) == catalogText(artist)) {
    title = prefix[2]!;
  }
  return catalogText(title.replaceAll(_guestCredit, ''));
}

List<String> catalogArtistNames(String value) => value
    .split(
      RegExp(
        r'\s+(?:feat\.?|ft\.?|featuring|with)\s+|\s*[,;&×]\s*',
        caseSensitive: false,
      ),
    )
    .map(catalogText)
    .where((s) => s.isNotEmpty)
    .toList();

bool _knownArtist(String artist) => !{
  '',
  'unknown',
  'unknown artist',
  'неизвестен',
  'неизвестный исполнитель',
  'various artists',
  'va',
  'v a',
  'сборник',
}.contains(catalogText(artist));

bool catalogArtistMatches(String artist, MusicRecording recording) {
  if (!_knownArtist(artist)) return false;
  final supplied = catalogText(artist);
  if (supplied == catalogText(recording.artist)) return true;
  final names = {
    catalogText(recording.catalogArtist),
    for (final a in recording.artists) ...[
      catalogText(a.name),
      ...a.aliases.map(catalogText),
    ],
  }..remove('');
  if (names.contains(supplied)) return true;
  final parts = catalogArtistNames(artist);
  return parts.isNotEmpty && parts.every(names.contains);
}

Set<String> _versions(String title, String album) {
  final text = catalogText('$title $album');
  return _versionWords.allMatches(text).map((m) => m[0]!).toSet();
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

int catalogDurationTolerance(int durationMs) =>
    math.max(2000, math.min(4000, (durationMs * .015).round()));

class CatalogMatch {
  const CatalogMatch({
    required this.recording,
    required this.score,
    required this.evidence,
    required this.conflicts,
    required this.automatic,
  });
  final MusicRecording recording;

  /// Ranking points, not a calibrated probability.
  final int score;
  final List<String> evidence, conflicts;
  final bool automatic;
}

CatalogMatch evaluateCatalogMatch(Track track, MusicRecording recording) {
  final evidence = <String>[], conflicts = <String>[];
  var score = 0;
  final title = catalogTitle(track.title, track.artist);
  final target = catalogTitle(recording.title, recording.catalogArtist);
  final exactTitle = title.isNotEmpty && title == target;
  if (exactTitle) {
    score += 45;
    evidence.add('title');
  } else {
    conflicts.add('title');
    // Close spellings are useful suggestions but never automatic identities.
    final a = title.split(' ').toSet(), b = target.split(' ').toSet();
    if (a.union(b).isNotEmpty) {
      score += (30 * a.intersection(b).length / a.union(b).length).round();
    }
  }
  final artist = catalogArtistMatches(track.artist, recording);
  if (artist) {
    score += 35;
    evidence.add('artist');
  } else {
    conflicts.add('artist');
  }
  final album = catalogText(track.album);
  final sameAlbum =
      album.isNotEmpty &&
      recording.albumTitles.any((a) => catalogText(a) == album);
  if (sameAlbum) {
    score += 8;
    evidence.add('album');
  }
  final durationKnown = track.durationMs > 0 && recording.durationMs > 0;
  if (durationKnown) {
    if ((track.durationMs - recording.durationMs).abs() <=
        catalogDurationTolerance(recording.durationMs)) {
      score += 12;
      evidence.add('duration');
    } else {
      conflicts.add('duration');
    }
  }
  // A live album context is evidence even if individual filenames omit Live.
  final sourceVersions = _versions(
    track.title,
    '${track.album} ${track.torrentAlbumPath ?? ''}',
  );
  final versions = _versions(recording.title, recording.disambiguation);
  if (!_sameSet(sourceVersions, versions) &&
      !(sameAlbum &&
          _sameSet(
            sourceVersions,
            _versions(
              recording.title,
              '${recording.disambiguation} ${track.album}',
            ),
          ))) {
    conflicts.add('version');
  }
  final reliable =
      track.source == TrackSource.local ||
      track.albumSource == TrackAlbumSource.tags;
  return CatalogMatch(
    recording: recording,
    score: score,
    evidence: List.unmodifiable(evidence),
    conflicts: List.unmodifiable(conflicts),
    automatic:
        reliable &&
        exactTitle &&
        artist &&
        durationKnown &&
        sameAlbum &&
        conflicts.isEmpty,
  );
}

/// ISRC alone cannot merge unrelated artists, edits or conflicting durations.
bool sameCatalogRecording(MusicRecording a, MusicRecording b) {
  if (a.keys.intersection(b.keys).isNotEmpty) return true;
  return a.isrcs.toSet().intersection(b.isrcs.toSet()).isNotEmpty &&
      catalogTitle(a.title, a.catalogArtist) ==
          catalogTitle(b.title, b.catalogArtist) &&
      catalogArtistMatches(a.catalogArtist, b) &&
      a.durationMs > 0 &&
      b.durationMs > 0 &&
      (a.durationMs - b.durationMs).abs() <=
          catalogDurationTolerance(a.durationMs) &&
      _sameSet(
        _versions(a.title, a.disambiguation),
        _versions(b.title, b.disambiguation),
      ) &&
      (a.explicit == null || b.explicit == null || a.explicit == b.explicit);
}

List<MusicRecording> mergeCatalogRecordings(
  Iterable<MusicRecording> recordings,
) {
  final merged = <MusicRecording>[];
  for (final recording in recordings) {
    final index = merged.indexWhere((r) => sameCatalogRecording(r, recording));
    if (index < 0) {
      merged.add(recording);
    } else {
      final old = merged[index];
      merged[index] =
          recording.provider == 'musicbrainz' && old.provider != 'musicbrainz'
          ? recording.withLinks(old)
          : old.withLinks(recording);
    }
  }
  return List.unmodifiable(merged);
}

List<CatalogMatch> rankCatalogMatches(
  Track track,
  Iterable<MusicRecording> recordings,
) =>
    mergeCatalogRecordings(
      recordings,
    ).map((r) => evaluateCatalogMatch(track, r)).toList()..sort((a, b) {
      final score = b.score.compareTo(a.score);
      return score == 0 ? a.recording.key.compareTo(b.recording.key) : score;
    });

CatalogMatch? automaticCatalogMatch(List<CatalogMatch> matches) {
  if (matches.isEmpty || !matches.first.automatic) return null;
  final first = matches.first;
  // A same-named artist or another recording with comparable evidence abstains.
  if (matches.skip(1).any((m) => first.score - m.score < 7)) return null;
  return first;
}
