part of 'library_repository.dart';

Track inspectAudioFile(
  String path,
  String artDirectory, {
  String? fallbackTitle,
  Track? torrent,
}) {
  final file = File(path);
  final id = torrent?.id ?? stableId(p.normalize(p.absolute(path)));
  final filename =
      fallbackTitle ?? p.basenameWithoutExtension(torrent?.torrentPath ?? path);
  final parent = p.basename(p.dirname(torrent?.torrentPath ?? path));
  final filenameNumber =
      int.tryParse(
        RegExp(r'^\s*(\d{1,3})[ ._\-]').firstMatch(filename)?.group(1) ?? '',
      ) ??
      0;
  final fallback = filename.replaceFirst(RegExp(r'^\s*\d{1,3}[ ._\-]+'), '');
  AudioMetadata? metadata;
  try {
    metadata = _readAudioMetadata(file);
  } catch (_) {
    /* Untagged audio remains playable. */
  }
  String? art;
  final picture = metadata?.pictures.firstOrNull;
  if (picture != null && picture.bytes.length < 16 * 1024 * 1024) {
    final dir = Directory(artDirectory)..createSync(recursive: true);
    final out = File(
      p.join(dir.path, '${stableId(base64Encode(picture.bytes))}.jpg'),
    );
    if (!out.existsSync()) out.writeAsBytesSync(picture.bytes);
    art = out.path;
  } else {
    for (final name in [
      'cover.jpg',
      'folder.jpg',
      'front.jpg',
      'cover.png',
      'folder.png',
    ]) {
      final candidate = File(p.join(file.parent.path, name));
      if (candidate.existsSync()) {
        art = candidate.path;
        break;
      }
    }
  }
  if (torrent != null) {
    String? value(String? text) =>
        text?.trim().isNotEmpty == true ? text!.trim() : null;
    final tagAlbum = value(metadata?.album);
    final tagAlbumArtist = value(metadata?.albumArtist);
    return torrent.copyWith(
      cachedPath: path,
      title: value(metadata?.title),
      artist: value(metadata?.artist),
      album: tagAlbum,
      albumSource: tagAlbum == null
          ? torrent.albumSource
          : TrackAlbumSource.tags,
      albumArtist: tagAlbumArtist ?? torrent.albumArtist ?? torrent.artist,
      albumArtistFromTags:
          tagAlbumArtist != null || torrent.albumArtistFromTags,
      artPath: art,
      durationMs: metadata?.duration?.inMilliseconds,
      number: metadata?.trackNumber,
      disc: metadata?.discNumber,
      year: (metadata?.year?.year ?? 0) > 0 ? metadata!.year!.year : null,
      lyrics: metadata?.lyrics,
    );
  }
  return Track(
    id: id,
    title: metadata?.title?.trim().isNotEmpty == true
        ? metadata!.title!
        : fallback,
    artist: metadata?.artist ?? 'Неизвестный исполнитель',
    albumArtist: metadata?.albumArtist,
    album:
        metadata?.album ??
        (parent == 'imports' ? 'Импортированная музыка' : parent),
    source: TrackSource.local,
    localPath: path,
    artPath: art,
    bytes: file.lengthSync(),
    durationMs: metadata?.duration?.inMilliseconds ?? 0,
    number: metadata?.trackNumber ?? filenameNumber,
    disc: metadata?.discNumber ?? 1,
    year: metadata?.year?.year,
    lyrics: metadata?.lyrics,
  );
}

AudioMetadata _readAudioMetadata(File file) {
  // The pinned generic MP3 mapper drops TPE2/albumArtist and uses it as TPE1.
  // Parse once through its public raw model, preserving the separate credits.
  if (p.extension(file.path).toLowerCase() == '.mp3') {
    final raw = readAllMetadata(file, getImage: true);
    if (raw is Mp3Metadata) {
      final year = raw.originalReleaseYear ?? raw.year;
      final metadata = AudioMetadata(
        file: file,
        title: raw.songName,
        album: raw.album,
        artist: raw.leadPerformer ?? raw.originalArtist ?? raw.bandOrOrchestra,
        albumArtist: raw.bandOrOrchestra,
        year: year == null || year <= 0 ? null : DateTime(year),
        duration: raw.duration,
        trackNumber: raw.trackNumber,
        trackTotal: raw.trackTotal,
        discNumber: raw.discNumber,
        totalDisc: raw.totalDics,
        lyrics: raw.lyric,
        language: raw.languages,
        bitrate: raw.bitrate,
        sampleRate: raw.samplerate,
      );
      metadata.pictures = raw.pictures;
      metadata.genres = raw.genres;
      return metadata;
    }
  }
  final metadata = readMetadata(file, getImage: true);
  if ({
    '.m4a',
    '.aac',
    '.alac',
    '.mp4',
  }.contains(p.extension(file.path).toLowerCase())) {
    try {
      final credits = _readMp4Artists(file);
      metadata.albumArtist = credits.albumArtist ?? metadata.albumArtist;
      metadata.artist =
          credits.artist ?? metadata.artist ?? credits.albumArtist;
    } catch (_) {
      // Malformed/unsupported supplemental atoms do not discard valid tags.
    }
  }
  return metadata;
}

/// Read only iTunes ©ART/aART credits omitted by the pinned generic mapper.
/// Media payload is skipped by seeking: bounded depth, atom count and tag size.
({String? artist, String? albumArtist}) _readMp4Artists(File file) {
  final reader = file.openSync();
  String? artist, albumArtist;
  var remainingAtoms = 10000;
  Uint8List readAt(int offset, int count) {
    reader.setPositionSync(offset);
    final data = reader.readSync(count);
    if (data.length != count) {
      throw const FormatException('Incomplete metadata atom.');
    }
    return data;
  }

  void walk(int start, int end, int depth, [String? field]) {
    if (depth > 8) return;
    var offset = start;
    while (offset <= end - 8 && --remainingAtoms >= 0) {
      final header = readAt(offset, 8);
      var size = ByteData.sublistView(header).getUint32(0);
      final type = latin1.decode(header.sublist(4));
      var headerSize = 8;
      if (size == 1) {
        if (offset > end - 16) return;
        size = ByteData.sublistView(readAt(offset + 8, 8)).getUint64(0);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < headerSize || size > end - offset) return;
      final atomEnd = offset + size;
      final payload = offset + headerSize;
      if ({'moov', 'udta', 'meta', 'ilst'}.contains(type)) {
        var childStart = payload;
        if (type == 'meta') {
          if (payload > atomEnd - 8) return;
          // Some QuickTime meta atoms omit ISO-BMFF's version/flags word.
          final firstType = latin1.decode(readAt(payload + 4, 4));
          if (!{'ilst', 'hdlr', 'free', 'keys'}.contains(firstType)) {
            childStart += 4;
          }
        }
        walk(childStart, atomEnd, depth + 1);
      } else if (type == '©ART' || type == 'aART') {
        walk(payload, atomEnd, depth + 1, type);
      } else if (type == 'data' &&
          field != null &&
          atomEnd - payload >= 8 &&
          atomEnd - payload - 8 <= 64 * 1024) {
        final encoding =
            ByteData.sublistView(readAt(payload, 4)).getUint32(0) & 0xffffff;
        final bytes = readAt(payload + 8, atomEnd - payload - 8);
        String? value;
        if (encoding == 0 || encoding == 1) {
          value = utf8.decode(bytes, allowMalformed: true);
        } else if (encoding == 2 && bytes.length.isEven) {
          final data = ByteData.sublistView(bytes);
          value = String.fromCharCodes([
            for (var index = 0; index < bytes.length; index += 2)
              data.getUint16(index),
          ]);
        }
        value = value
            ?.replaceFirst('\uFEFF', '')
            .replaceAll('\u0000', '')
            .trim();
        if (value?.isNotEmpty == true) {
          if (field == '©ART') {
            artist ??= value;
          } else {
            albumArtist ??= value;
          }
        }
      }
      offset = atomEnd;
    }
  }

  try {
    walk(0, reader.lengthSync(), 0);
    return (artist: artist, albumArtist: albumArtist);
  } finally {
    reader.closeSync();
  }
}

Track _mergeTorrentImport(Track old, Track inferred) {
  final enriched =
      old.albumSource == TrackAlbumSource.tags ||
      old.albumSource == TrackAlbumSource.sibling;
  return old.copyWith(
    album: enriched ? old.album : inferred.album,
    albumArtist: enriched || old.albumArtistFromTags
        ? old.albumArtist
        : inferred.albumArtist,
    torrentAlbumPath: inferred.torrentAlbumPath,
    albumSource: enriched ? old.albumSource : inferred.albumSource,
    year: old.year ?? inferred.year,
    disc: enriched ? old.disc : inferred.disc,
    artPath: old.artPath ?? inferred.artPath,
  );
}

List<Track> _propagateTorrentAlbumMetadata(Iterable<Track> tracks) {
  final items = tracks.toList();
  final groups = <String, List<Track>>{};
  for (final track in items) {
    // A flat mixed collection provides no evidence that tracks share an album.
    if (track.source != TrackSource.torrent ||
        track.torrentHash == null ||
        track.torrentAlbumPath == null) {
      continue;
    }
    groups
        .putIfAbsent(
          '${track.torrentHash}\u0000${track.torrentAlbumPath}',
          () => [],
        )
        .add(track);
  }
  final updated = <String, Track>{};
  for (final group in groups.values) {
    group.sort((a, b) => (a.torrentIndex ?? 0).compareTo(b.torrentIndex ?? 0));
    final canonical =
        group
            .where((track) => track.albumSource == TrackAlbumSource.tags)
            .firstOrNull ??
        group.where((track) => track.albumArtistFromTags).firstOrNull;
    if (canonical == null) {
      continue;
    }
    final albumArtist =
        group
            .where(
              (track) =>
                  track.albumArtistFromTags &&
                  (track.albumSource != TrackAlbumSource.tags ||
                      track.album == canonical.album),
            )
            .firstOrNull
            ?.albumArtist ??
        canonical.albumArtist ??
        canonical.artist;
    for (final track in group) {
      if (track.albumSource == TrackAlbumSource.tags &&
          track.album != canonical.album) {
        continue;
      }
      final explicit = track.albumSource == TrackAlbumSource.tags;
      updated[track.id] = track.copyWith(
        album: explicit ? track.album : canonical.album,
        albumSource: explicit ? track.albumSource : TrackAlbumSource.sibling,
        albumArtist: track.albumArtistFromTags
            ? track.albumArtist
            : albumArtist,
        year: explicit ? track.year : canonical.year,
      );
    }
  }
  return items.map((track) => updated[track.id] ?? track).toList();
}
