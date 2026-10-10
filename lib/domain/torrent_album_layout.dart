import 'models.dart';
import 'music_metadata.dart';

/// Album hints obtained from metainfo paths, before any audio is downloaded.
class TorrentAlbumIdentity {
  const TorrentAlbumIdentity({
    required this.album,
    required this.artist,
    required this.folder,
    required this.source,
    this.year,
    this.disc = 1,
  });
  final String album, artist;
  // null means a flat mixed collection; '' means a trusted flat album.
  final String? folder;
  final TrackAlbumSource source;
  final int? year;
  final int disc;
}

class TorrentAlbumLayout {
  TorrentAlbumLayout(TorrentInfo info, {String? releaseTitle, String? artist})
    : _title = _nonempty(releaseTitle) ?? info.title,
      _infoTitle = info.title,
      _artist = _nonempty(artist) {
    final paths = info.files
        .where((file) => isAudioPath(file.path))
        .map((file) => _parts(file.path))
        .toList();
    // TorrServer includes the metainfo root in multi-file paths. It identifies
    // the source, rather than a separate album, even for a one-album torrent.
    _root =
        paths.isNotEmpty &&
            paths.every(
              (parts) => parts.length > 1 && parts.first == paths.first.first,
            )
        ? paths.first.first
        : null;
  }

  final String _title, _infoTitle;
  final String? _artist;
  String? _root;

  TorrentAlbumIdentity forPath(String path) {
    final identity = _mixedRelease(_title)
        ? null
        : parseReleaseIdentity(_title) ??
              (_mixedRelease(_infoTitle)
                  ? null
                  : parseReleaseIdentity(_infoTitle));
    var artist =
        _artist ??
        identity?.artist ??
        inferredReleaseArtist(_title) ??
        inferredReleaseArtist(_infoTitle) ??
        'Неизвестный исполнитель';
    final parts = _parts(path);
    final directories = parts.take(parts.length - 1).toList();
    var disc = parseTorrentTrackName(parts.last).disc ?? 1;
    final logical = <String>[];
    final candidates = <String>[];
    var flatCategory = false;
    for (var index = 0; index < directories.length; index++) {
      final directory = directories[index];
      if (index == 0 && directory == _root) {
        continue;
      }
      final directoryDisc = _discDirectory(directory);
      if (directoryDisc != null) {
        disc = directoryDisc;
        continue;
      }
      if (_formatWrapper(directory)) {
        continue;
      }
      if (_categoryWrapper(directory)) {
        final albumBelow = directories
            .skip(index + 1)
            .any(
              (item) =>
                  _discDirectory(item) == null &&
                  !_formatWrapper(item) &&
                  !_categoryWrapper(item),
            );
        if (albumBelow) {
          continue;
        }
        // A leaf literally named Album (or Live) can be an actual album.
        // Explicit mixed categories never establish a shared album identity.
        if (!RegExp(
          r'^(?:album|live)$',
          caseSensitive: false,
        ).hasMatch(directory.trim())) {
          flatCategory = true;
          continue;
        }
      }
      logical.add(directory);
      candidates.add(directory);
    }
    if (flatCategory) {
      if (artist == 'Неизвестный исполнитель' && candidates.isNotEmpty) {
        artist = candidates.last;
      }
      logical.clear();
      candidates.clear();
    } else if (candidates.length == 1 &&
        normalizeMusicName(candidates.single) == normalizeMusicName(artist)) {
      logical.clear();
      candidates.clear();
    }
    final folder = logical.join('/');
    if (candidates.isEmpty) {
      final album =
          (_mixedRelease(_title) ? null : parseReleaseIdentity(_title))
              ?.album ??
          (_nonempty(_title) == _nonempty(_infoTitle)
              ? identity?.album ?? _title
              : _title);
      return TorrentAlbumIdentity(
        album: album,
        artist: artist,
        folder: identity == null || flatCategory ? null : folder,
        source: TrackAlbumSource.release,
        year: _albumName(_title).year ?? _releaseYear(_title),
        disc: disc,
      );
    }
    final rawAlbum = candidates.last;
    final parsed = _albumName(rawAlbum);
    var album = parsed.title;
    // An artist directory is stronger evidence than an unknown release name.
    // Do not treat the first half of every album title containing '-' as artist.
    if (artist == 'Неизвестный исполнитель' && candidates.length > 1) {
      artist = candidates[candidates.length - 2];
    }
    final artistPrefix = RegExp(
      '^${RegExp.escape(artist)}\\s+[–—-]\\s+',
      caseSensitive: false,
    );
    album = album.replaceFirst(artistPrefix, '').trim();
    return TorrentAlbumIdentity(
      album: album.isEmpty ? parsed.title : album,
      artist: artist,
      folder: folder,
      source: TrackAlbumSource.directory,
      year: parsed.year,
      disc: disc,
    );
  }
}

({String title, int number, int? disc}) parseTorrentTrackName(String path) {
  final filename = _parts(path).last.replaceFirst(RegExp(r'\.[^.]+$'), '');
  final multiDisc = RegExp(
    r'^\s*(\d{1,2})[-_.](\d{1,3})[ ._\-]+',
  ).firstMatch(filename);
  if (multiDisc != null) {
    return (
      title: filename.substring(multiDisc.end).trim(),
      number: int.parse(multiDisc.group(2)!),
      disc: int.parse(multiDisc.group(1)!),
    );
  }
  final number = RegExp(r'^\s*(\d{1,3})[ ._\-]+').firstMatch(filename);
  return (
    title: number == null
        ? filename.trim()
        : filename.substring(number.end).trim(),
    number: number == null ? 0 : int.parse(number.group(1)!),
    disc: null,
  );
}

List<String> _parts(String path) => path
    .replaceAll('\\', '/')
    .split('/')
    .where((part) => part.isNotEmpty && part != '.')
    .toList();
String? _nonempty(String? value) =>
    value?.trim().isNotEmpty == true ? value!.trim() : null;

int? _releaseYear(String title) => int.tryParse(
  RegExp(
        r'(?:[\[(,;]\s*)((?:19|20)\d{2})(?:[,\s\])]|$)',
      ).firstMatch(title)?.group(1) ??
      '',
);

int? _discDirectory(String directory) {
  final value = directory.replaceAll(RegExp(r'[\[\]()]'), '').trim();
  final match = RegExp(
    r'^(?:cd|disc|disk|диск)\s*[-_. ]*0*(\d{1,2})(?:\s*(?:of|из)\s*\d+|\s*[-–—].*)?$',
    caseSensitive: false,
  ).firstMatch(value);
  return match == null ? null : int.tryParse(match.group(1)!);
}

bool _mixedRelease(String title) => RegExp(
  r'дискограф|трекограф|discograph|trackograph|collection|сборник|various artists|\bva\b',
  caseSensitive: false,
).hasMatch(title);

bool _categoryWrapper(String directory) {
  final value = directory.replaceAll(RegExp(r'[\[\]()]'), '').trim();
  return RegExp(
    r'^\+?\s*(?:albums?|studio albums?|classical|compilations?|live|singles(?:\s*&\s*eps?)?|singles\s*&\s*ep.s|eps?|mixtapes?|discography|trackography|дискография|трекография|альбомы|сборники|mccartney archive collection)$',
    caseSensitive: false,
  ).hasMatch(value);
}

bool _formatWrapper(String directory) {
  final value = directory.replaceAll(RegExp(r'[\[\]()]'), '').trim();
  return RegExp(
        r'^(?:(?:web\s*)?(?:flac|mp3|aac|alac|wav|ape|m4a|ogg|opus|lossless|audio|tracks)(?:[\s_.,+/\-]*(?:\d+(?:\.\d+)?|kbps|kbit|bit|bits|khz|hz|cbr|vbr|stereo))*)$',
        caseSensitive: false,
      ).hasMatch(value) ||
      RegExp(
        r'^\d+(?:\s*bit)?[\s_./\-]+\d+(?:\.\d+)?\s*khz$',
        caseSensitive: false,
      ).hasMatch(value);
}

({String title, int? year}) _albumName(String directory) {
  var title = directory.trim();
  // Collection numbering is independent of the release year: [68] (2025).
  title = title.replaceFirst(RegExp(r'^\[\d{1,3}\]\s*'), '');
  final prefix = RegExp(
    r'^[\[(]?((?:19|20)\d{2})(?:[-_.]\d{2}[-_.]\d{2})?[\])]?(?:\s*[.\-–—]\s*|\s+)',
  ).firstMatch(title);
  int? year;
  if (prefix != null && title.substring(prefix.end).trim().isNotEmpty) {
    year = int.parse(prefix.group(1)!);
    title = title.substring(prefix.end).trim();
  } else {
    final suffix = RegExp(
      r'\s*[\[(]((?:19|20)\d{2})[\])]\s*$',
    ).firstMatch(title);
    if (suffix != null && title.substring(0, suffix.start).trim().isNotEmpty) {
      year = int.parse(suffix.group(1)!);
      title = title.substring(0, suffix.start).trim();
    }
  }
  title = title
      .replaceFirst(
        RegExp(
          r'\s*[\[(](?:ep|lp|single|mixtape)[\])]\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  return (title: title, year: year);
}
