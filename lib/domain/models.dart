import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const audioExtensions = {
  'mp3',
  'flac',
  'm4a',
  'aac',
  'ogg',
  'opus',
  'wav',
  'aiff',
  'aif',
  'ape',
  'wma',
  'webm',
  'alac',
};
bool isAudioPath(String path) => audioExtensions.contains(
  p.extension(path).replaceFirst('.', '').toLowerCase(),
);
String stableId(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 24);
String formatTime(Duration time) =>
    '${time.inMinutes}:${(time.inSeconds % 60).toString().padLeft(2, '0')}';
String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} ГБ';
}

enum TrackSource { local, torrent, demo }

enum TrackAlbumSource { release, directory, tags, sibling }

enum PlayerRepeatMode { off, all, one }

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.source,
    this.albumArtist,
    this.localPath,
    this.artPath,
    this.torrentHash,
    this.torrentLink,
    this.torrentIndex,
    this.torrentPath,
    this.cachedPath,
    this.bytes = 0,
    this.durationMs = 0,
    this.number = 0,
    this.disc = 1,
    this.year,
    this.lyrics,
    this.torrentAlbumPath,
    this.albumSource,
    this.albumArtistFromTags = false,
  });
  final String id, title, artist, album;
  final TrackSource source;
  final String? albumArtist,
      localPath,
      artPath,
      torrentHash,
      torrentLink,
      torrentPath,
      cachedPath,
      lyrics,
      torrentAlbumPath;
  final TrackAlbumSource? albumSource;
  final bool albumArtistFromTags;
  final int? torrentIndex, year;
  final int bytes, durationMs, number, disc;
  Duration get duration => Duration(milliseconds: durationMs);
  String get albumKey => stableId('${albumArtist ?? artist}\u0000$album');
  bool get offline => localPath != null || cachedPath != null;
  String get format => p
      .extension(torrentPath ?? localPath ?? '')
      .replaceFirst('.', '')
      .toUpperCase();
  Track copyWith({
    String? cachedPath,
    bool clearCache = false,
    String? artPath,
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    int? durationMs,
    int? number,
    int? disc,
    int? year,
    String? lyrics,
    String? torrentAlbumPath,
    TrackAlbumSource? albumSource,
    bool? albumArtistFromTags,
  }) => Track(
    id: id,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    albumArtist: albumArtist ?? this.albumArtist,
    source: source,
    localPath: localPath,
    artPath: artPath ?? this.artPath,
    torrentHash: torrentHash,
    torrentLink: torrentLink,
    torrentIndex: torrentIndex,
    torrentPath: torrentPath,
    cachedPath: clearCache ? null : cachedPath ?? this.cachedPath,
    bytes: bytes,
    durationMs: durationMs ?? this.durationMs,
    number: number ?? this.number,
    disc: disc ?? this.disc,
    year: year ?? this.year,
    lyrics: lyrics ?? this.lyrics,
    torrentAlbumPath: torrentAlbumPath ?? this.torrentAlbumPath,
    albumSource: albumSource ?? this.albumSource,
    albumArtistFromTags: albumArtistFromTags ?? this.albumArtistFromTags,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'albumArtist': albumArtist,
    'source': source.name,
    'localPath': localPath,
    'artPath': artPath,
    'torrentHash': torrentHash,
    'torrentLink': torrentLink,
    'torrentIndex': torrentIndex,
    'torrentPath': torrentPath,
    'cachedPath': cachedPath,
    'bytes': bytes,
    'durationMs': durationMs,
    'number': number,
    'disc': disc,
    'year': year,
    'lyrics': lyrics,
    if (torrentAlbumPath != null) 'torrentAlbumPath': torrentAlbumPath,
    if (albumSource != null) 'albumSource': albumSource!.name,
    if (albumArtistFromTags) 'albumArtistFromTags': true,
  };
  factory Track.fromJson(Map<String, dynamic> j) => Track(
    id: j['id'] as String,
    title: j['title'] as String,
    artist: j['artist'] as String,
    album: j['album'] as String,
    albumArtist: j['albumArtist'] as String?,
    source: TrackSource.values.byName(j['source'] as String),
    localPath: j['localPath'] as String?,
    artPath: j['artPath'] as String?,
    torrentHash: j['torrentHash'] as String?,
    torrentLink: j['torrentLink'] as String?,
    torrentIndex: j['torrentIndex'] as int?,
    torrentPath: j['torrentPath'] as String?,
    cachedPath: j['cachedPath'] as String?,
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
    number: j['number'] as int? ?? 0,
    disc: j['disc'] as int? ?? 1,
    year: j['year'] as int?,
    lyrics: j['lyrics'] as String?,
    torrentAlbumPath: j['torrentAlbumPath'] as String?,
    albumSource: TrackAlbumSource.values
        .where((source) => source.name == j['albumSource'])
        .firstOrNull,
    albumArtistFromTags: j['albumArtistFromTags'] == true,
  );
}

class Album {
  Album(this.tracks) : assert(tracks.isNotEmpty);
  final List<Track> tracks;
  String get id => tracks.first.albumKey;
  String get title => tracks.first.album;
  String get artist => tracks.first.albumArtist ?? tracks.first.artist;
  String? get artPath =>
      tracks.map((t) => t.artPath).whereType<String>().firstOrNull;
  int? get year => tracks.first.year;
  bool get offline => tracks.every((t) => t.offline);
  bool get torrent => tracks.any((t) => t.source == TrackSource.torrent);
}

List<Album> groupAlbums(Iterable<Track> tracks) {
  final groups = <String, List<Track>>{};
  for (final track in tracks) {
    groups.putIfAbsent(track.albumKey, () => []).add(track);
  }
  return groups.values.map((items) {
    items.sort((a, b) {
      final disc = a.disc.compareTo(b.disc);
      if (disc != 0) return disc;
      final number = a.number.compareTo(b.number);
      return number != 0 ? number : a.title.compareTo(b.title);
    });
    return Album(List.unmodifiable(items));
  }).toList();
}

class MusicPlaylist {
  const MusicPlaylist({
    required this.id,
    required this.name,
    this.trackIds = const [],
    this.sourceHash,
  });
  final String id, name;
  final List<String> trackIds;
  final String? sourceHash;
  MusicPlaylist copyWith({String? name, List<String>? trackIds}) =>
      MusicPlaylist(
        id: id,
        name: name ?? this.name,
        trackIds: trackIds ?? this.trackIds,
        sourceHash: sourceHash,
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'trackIds': trackIds,
    if (sourceHash != null) 'sourceHash': sourceHash,
  };
  factory MusicPlaylist.fromJson(Map<String, dynamic> j) => MusicPlaylist(
    id: j['id'] as String,
    name: j['name'] as String,
    trackIds: List<String>.from(j['trackIds'] as List),
    sourceHash: j['sourceHash'] as String?,
  );
}

class TorrentFile {
  const TorrentFile({
    required this.index,
    required this.path,
    required this.bytes,
  });
  final int index, bytes;
  final String path;
  factory TorrentFile.fromJson(Map<String, dynamic> j) => TorrentFile(
    index: (j['id'] as num).toInt(),
    path: j['path'] as String,
    bytes: (j['length'] as num?)?.toInt() ?? 0,
  );
}

class TorrentInfo {
  const TorrentInfo({
    required this.hash,
    required this.title,
    required this.files,
    this.speed = 0,
    this.peers = 0,
    this.status = '',
  });
  final String hash, title, status;
  final List<TorrentFile> files;
  final double speed;
  final int peers;
  factory TorrentInfo.fromJson(Map<String, dynamic> j) => TorrentInfo(
    hash: j['hash'] as String,
    title: (j['title'] as String?)?.trim().isNotEmpty == true
        ? j['title'] as String
        : (j['name'] as String? ?? 'Альбом'),
    files: ((j['file_stats'] as List?) ?? [])
        .map((e) => TorrentFile.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    speed: (j['download_speed'] as num?)?.toDouble() ?? 0,
    peers: (j['active_peers'] as num?)?.toInt() ?? 0,
    status: j['stat_string'] as String? ?? '',
  );
}

class SearchRelease {
  const SearchRelease({
    required this.title,
    required this.link,
    this.bytes = 0,
    this.seeders = 0,
    this.rutracker = false,
    this.category = '',
    this.magnetLink,
    this.indexerName = '',
    this.detailsUrl = '',
    this.seedersKnown = true,
  });
  final String title, link, category, indexerName, detailsUrl;
  final String? magnetLink;
  final int bytes, seeders;
  final bool rutracker;
  final bool seedersKnown;
}
