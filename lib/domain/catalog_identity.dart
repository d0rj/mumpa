String catalogText(String value) => value
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

class CatalogArtist {
  const CatalogArtist({
    required this.id,
    required this.name,
    this.provider = 'musicbrainz',
    this.aliases = const [],
  });
  final String id, name, provider;
  final List<String> aliases;
  String get key => '$provider:$id';
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider,
    'aliases': aliases,
  };
  factory CatalogArtist.fromJson(Map<String, dynamic> j) => CatalogArtist(
    id: j['id'] as String,
    name: j['name'] as String,
    provider: j['provider'] as String? ?? 'musicbrainz',
    aliases: List<String>.unmodifiable(j['aliases'] as List? ?? []),
  );
}

/// Provider IDs are namespaced. A recording describes a performance, not a file.
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
    this.provider = 'musicbrainz',
    this.artistCredits = const [],
    this.isrcs = const [],
    this.linkedIds = const [],
    this.explicit,
  });
  final String id, title, artist, disambiguation, primaryArtist, provider;
  final String? artistId;
  final int durationMs;
  final List<String> albumTitles, isrcs, linkedIds;
  final List<CatalogArtist> artistCredits;
  final bool? explicit;
  String get key => '$provider:$id';
  String get catalogArtist => primaryArtist.isEmpty ? artist : primaryArtist;
  List<CatalogArtist> get artists => artistCredits.isNotEmpty
      ? artistCredits
      : artistId == null
      ? const []
      : [CatalogArtist(id: artistId!, name: catalogArtist, provider: provider)];
  Set<String> get keys => {key, ...linkedIds};
  String? get musicBrainzArtistId =>
      artists.where((a) => a.provider == 'musicbrainz').firstOrNull?.id;
  MusicRecording withLinks(MusicRecording other) => MusicRecording(
    id: id,
    title: title,
    artist: artist,
    artistId: artistId,
    durationMs: durationMs,
    albumTitles: List.unmodifiable({...albumTitles, ...other.albumTitles}),
    disambiguation: disambiguation,
    primaryArtist: primaryArtist,
    provider: provider,
    explicit: explicit ?? other.explicit,
    isrcs: List.unmodifiable({...isrcs, ...other.isrcs}),
    linkedIds: List.unmodifiable({...linkedIds, ...other.keys}..remove(key)),
    artistCredits: List.unmodifiable(
      {
        for (final a in [...other.artists, ...artists])
          a.key: CatalogArtist(
            id: a.id,
            name: a.name,
            provider: a.provider,
            aliases: List.unmodifiable(
              {
                ...a.aliases,
                for (final b in [...artists, ...other.artists])
                  if (b.key == a.key) ...[b.name, ...b.aliases],
              }..remove(a.name),
            ),
          ),
      }.values,
    ),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'artistId': artistId,
    'durationMs': durationMs,
    'albumTitles': albumTitles,
    'disambiguation': disambiguation,
    'primaryArtist': primaryArtist,
    'provider': provider,
    'artistCredits': artists.map((a) => a.toJson()).toList(),
    'isrcs': isrcs,
    'linkedIds': linkedIds,
    'explicit': explicit,
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
    provider: j['provider'] as String? ?? 'musicbrainz',
    artistCredits: List.unmodifiable(
      (j['artistCredits'] as List? ?? []).map(
        (a) => CatalogArtist.fromJson(Map<String, dynamic>.from(a as Map)),
      ),
    ),
    isrcs: List<String>.unmodifiable(j['isrcs'] as List? ?? []),
    linkedIds: List<String>.unmodifiable(j['linkedIds'] as List? ?? []),
    explicit: j['explicit'] as bool?,
  );
}

/// Saved in library.json, never in the disposable provider response cache.
class TrackCatalogLink {
  const TrackCatalogLink({
    required this.recording,
    required this.matchedAt,
    required this.manual,
    this.evidence = const [],
    this.matcherVersion = 1,
  });
  final MusicRecording recording;
  final DateTime matchedAt;
  final bool manual;
  final List<String> evidence;
  final int matcherVersion;
  Map<String, dynamic> toJson() => {
    'recording': recording.toJson(),
    'matchedAt': matchedAt.toUtc().toIso8601String(),
    'manual': manual,
    'evidence': evidence,
    'matcherVersion': matcherVersion,
  };
  factory TrackCatalogLink.fromJson(Map<String, dynamic> j) => TrackCatalogLink(
    recording: MusicRecording.fromJson(
      Map<String, dynamic>.from(j['recording'] as Map),
    ),
    matchedAt: DateTime.parse(j['matchedAt'] as String),
    manual: j['manual'] == true,
    evidence: List<String>.unmodifiable(j['evidence'] as List? ?? []),
    matcherVersion: j['matcherVersion'] as int? ?? 1,
  );
}
