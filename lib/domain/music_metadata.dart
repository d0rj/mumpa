import 'models.dart';

String normalizeMusicName(String value) => value
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

String musicSearchPhrase(String value) => value
    .replaceAll(RegExp(r'["\\]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

class MusicReleaseGroup {
  const MusicReleaseGroup({
    required this.id,
    required this.title,
    required this.artist,
    this.year = '',
    this.type = '',
  });
  final String id, title, artist, year, type;
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'year': year,
    'type': type,
  };
  factory MusicReleaseGroup.fromJson(Map<String, dynamic> j) =>
      MusicReleaseGroup(
        id: j['id'] as String,
        title: j['title'] as String,
        artist: j['artist'] as String,
        year: j['year'] as String? ?? '',
        type: j['type'] as String? ?? '',
      );
}

class MusicRecording {
  const MusicRecording({
    required this.id,
    required this.title,
    required this.artist,
    this.artistId,
    this.durationMs = 0,
    this.albumTitles = const [],
    this.disambiguation = '',
    this.primaryArtist = '',
  });
  final String id, title, artist, disambiguation;
  final String primaryArtist;
  String get catalogArtist => primaryArtist.isEmpty ? artist : primaryArtist;
  final String? artistId;
  final int durationMs;
  final List<String> albumTitles;
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'artistId': artistId,
    'durationMs': durationMs,
    'albumTitles': albumTitles,
    'disambiguation': disambiguation,
    'primaryArtist': primaryArtist,
  };
  factory MusicRecording.fromJson(Map<String, dynamic> j) => MusicRecording(
    id: j['id'] as String,
    title: j['title'] as String,
    artist: j['artist'] as String,
    artistId: j['artistId'] as String?,
    durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
    albumTitles: List<String>.unmodifiable(j['albumTitles'] as List? ?? []),
    disambiguation: j['disambiguation'] as String? ?? '',
    primaryArtist: j['primaryArtist'] as String? ?? '',
  );
}

class MusicArtist {
  const MusicArtist({
    required this.id,
    required this.name,
    this.type = '',
    this.country = '',
    this.disambiguation = '',
    this.aliases = const [],
    this.albums = const [],
    this.recordings = const [],
  });
  final String id, name, type, country, disambiguation;
  final List<String> aliases;
  final List<MusicReleaseGroup> albums;
  final List<MusicRecording> recordings;
  bool matches(String name) => [
    this.name,
    ...aliases,
  ].any((alias) => normalizeMusicName(alias) == normalizeMusicName(name));
}

class TrackVariant {
  const TrackVariant({
    required this.release,
    required this.track,
    required this.info,
    required this.source,
    required this.edition,
  });
  final SearchRelease release;
  final Track track;
  final TorrentInfo info;
  final String source, edition;
  String get format => track.format;
}

String describeEdition(String title) {
  if (RegExp(
    r'\b(uncensored|explicit|unedited|dirty)\b|без цензуры|нецензур',
    caseSensitive: false,
  ).hasMatch(title)) {
    return 'Без цензуры · по описанию';
  }
  if (RegExp(
    r'\b(clean|censored|radio edit)\b|цензурная версия',
    caseSensitive: false,
  ).hasMatch(title)) {
    return 'Clean · по описанию';
  }
  return 'Цензура не указана';
}

String describeReleaseFormats(String title) {
  final formats = [
    'FLAC',
    'MP3',
    'ALAC',
    'AAC',
    'M4A',
    'OGG',
    'OPUS',
    'WAV',
    'APE',
  ];
  return formats
      .where((f) => RegExp('\\b$f\\b', caseSensitive: false).hasMatch(title))
      .join(' / ');
}

/// Release titles are hints. They never establish an exact MusicBrainz match.
String _stripReleasePrefix(String raw) {
  var title = raw.trim();
  while (true) {
    final stripped = title
        .replaceFirst(RegExp(r'^\s*[\[(][^\])]+[\])]\s*'), '')
        .trim();
    if (stripped == title) return title;
    title = stripped;
  }
}

String? inferredReleaseArtist(String raw) {
  final parts = _stripReleasePrefix(raw).split(RegExp(r'\s+[–—-]\s+'));
  if (parts.length < 2) return null;
  final artist = parts.first.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();
  if (artist.isEmpty ||
      RegExp(
        r'^(?:va|v a|various artists|сборник)$',
        caseSensitive: false,
      ).hasMatch(normalizeMusicName(artist))) {
    return null;
  }
  return artist;
}

({String artist, String album})? parseReleaseIdentity(String raw) {
  var title = _stripReleasePrefix(raw);
  final parts = title.split(RegExp(r'\s+[–—-]\s+'));
  if (parts.length < 2) return null;
  final artist = inferredReleaseArtist(raw) ?? '';
  title = parts.skip(1).join(' - ');
  title = title.replaceAll(RegExp(r'\s*[\[(](?:19|20)\d{2}[^\])]*[\])].*'), '');
  title = title.replaceAll(RegExp(r'\s*[,;]\s*(?:19|20)\d{2}.*'), '');
  title = title.replaceAll(
    RegExp(r'\s*[,;]\s*(?:FLAC|MP3|ALAC|AAC|WAV|APE).*', caseSensitive: false),
    '',
  );
  title = title.replaceAll(
    RegExp(
      r'\s*[\[(][^\])]*(?:FLAC|MP3|ALAC|AAC|WAV|APE)[^\])]*[\])].*',
      caseSensitive: false,
    ),
    '',
  );
  title = title.replaceAll(RegExp(r'\s*[\[(][^\])]*[\])]\s*$'), '').trim();
  if (artist.isEmpty ||
      title.isEmpty ||
      RegExp(
        r'дискограф|discograph|collection|сборник|various artists|^va$',
        caseSensitive: false,
      ).hasMatch('$artist $title')) {
    return null;
  }
  return (artist: artist, album: title);
}

bool matchesRecordingFilename(String path, MusicRecording recording) {
  var name = path.replaceAll('\\', '/').split('/').last;
  name = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
  name = name.replaceFirst(RegExp(r'^\d{1,3}[ ._\-]+'), '');
  final title = normalizeMusicName(recording.title);
  final normalized = normalizeMusicName(name);
  if (title.isEmpty) return false;
  if (normalized == title ||
      normalized ==
          normalizeMusicName('${recording.artist} ${recording.title}') ||
      normalized ==
          normalizeMusicName('${recording.catalogArtist} ${recording.title}')) {
    return true;
  }
  // Version suffixes are preserved in the variant label rather than collapsed.
  final withoutVersion = normalizeMusicName(
    name.replaceAll(
      RegExp(
        r'\s*[\[(](?:explicit|clean|uncensored|radio edit|remaster(?:ed)?[^\])]*|[^\])]*version)[\])]\s*$',
        caseSensitive: false,
      ),
      '',
    ),
  );
  return withoutVersion == title ||
      withoutVersion ==
          normalizeMusicName('${recording.artist} ${recording.title}');
}
