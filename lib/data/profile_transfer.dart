import 'dart:convert';
import 'dart:math' as math;

import '../domain/models.dart';
import 'library_storage.dart';

/// A portable metadata document. Device paths and connection credentials never
/// cross this boundary, including when reading a hand-edited transfer file.
class ProfileTransfer {
  ProfileTransfer._(this._profile);

  static const maxBytes = 64 * 1024 * 1024;
  final Map<String, dynamic> _profile;
  int get trackCount => (_profile['tracks'] as List).length;
  int get playlistCount => (_profile['playlists'] as List).length;
  int get favoriteCount => (_profile['liked'] as List).length;
  int get albumCount => (_profile['likedAlbums'] as List).length;
  int get localTrackCount => (_profile['tracks'] as List)
      .where((track) => track['source'] == 'local')
      .length;

  static ProfileTransfer fromSnapshot(Map<String, dynamic> snapshot) =>
      ProfileTransfer._(_portable(snapshot));

  String encode({DateTime? now}) => jsonEncode({
    'format': 'mumpa-profile',
    'version': 1,
    'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'profile': _profile,
  });

  static ProfileTransfer decode(String contents) {
    try {
      if (utf8.encode(contents).length > maxBytes) {
        throw const FormatException('Файл профиля больше 64 МБ.');
      }
      final document = jsonDecode(contents) as Map<String, dynamic>;
      if (document['format'] != 'mumpa-profile') {
        throw const FormatException('Это не файл переноса профиля Mumpa.');
      }
      if (document['version'] != 1) {
        throw const FormatException(
          'Версия файла профиля не поддерживается. Обнови Mumpa.',
        );
      }
      final profile = Map<String, dynamic>.from(document['profile'] as Map);
      for (final key in [
        'tracks',
        'playlists',
        'liked',
        'likedAlbums',
        'likedPlaylists',
        'recent',
        'retainedTrackIds',
        'trackMatchExcluded',
        'preferredTrackVariants',
      ]) {
        if (profile[key] is! List) throw const FormatException();
      }
      for (final key in ['settings', 'trackPlayCounts', 'playlistPlayCounts']) {
        if (profile[key] is! Map) throw const FormatException();
      }
      return ProfileTransfer._(_portable(profile));
    } on FormatException catch (error) {
      if (error.message.isNotEmpty) rethrow;
      throw const FormatException('Файл профиля повреждён или неполон.');
    } catch (_) {
      throw const FormatException('Файл профиля повреждён или неполон.');
    }
  }

  static Map<String, dynamic> _portable(Map<String, dynamic> snapshot) {
    LibraryStorage.decode(jsonEncode(snapshot));
    final tracks = [
      for (final row in snapshot['tracks'] as List)
        _portableTrack(Track.fromJson(Map<String, dynamic>.from(row as Map))),
    ];
    final playlists = [
      for (final row in snapshot['playlists'] as List? ?? [])
        MusicPlaylist.fromJson(Map<String, dynamic>.from(row as Map)).toJson(),
    ];
    final trackIds = tracks.map((track) => track['id'] as String).toSet();
    final playlistIds = playlists
        .map((playlist) => playlist['id'] as String)
        .toSet();
    if (trackIds.length != tracks.length ||
        playlistIds.length != playlists.length ||
        [
          ...trackIds,
          ...playlistIds,
        ].any((id) => !RegExp(r'^[a-zA-Z0-9:_-]{1,128}$').hasMatch(id)) ||
        playlistIds.contains(MusicPlaylist.deviceTop50Id)) {
      throw const FormatException(
        'В профиле повторяются или повреждены идентификаторы.',
      );
    }
    List<String> refs(Object? value, Set<String> allowed) {
      final ids = List<String>.from(value as List? ?? []);
      if (ids.any((id) => !allowed.contains(id))) {
        throw const FormatException(
          'В профиле есть ссылки на отсутствующие записи.',
        );
      }
      return ids;
    }

    for (final playlist in playlists) {
      refs(playlist['trackIds'], trackIds);
    }
    Map<String, int> counts(String key, Set<String> allowed) {
      final result = Map<String, int>.from(snapshot[key] as Map? ?? {});
      if (result.keys.any((id) => !allowed.contains(id))) {
        throw const FormatException('В статистике есть неизвестные записи.');
      }
      return result;
    }

    final settings = _portableSettings(
      snapshot['settings'] as Map? ?? {},
      trackIds,
      playlistIds,
    );
    return {
      'version': 1,
      'tracks': tracks,
      'playlists': playlists,
      'liked': refs(snapshot['liked'], trackIds),
      'likedPlaylists': refs(snapshot['likedPlaylists'], playlistIds),
      'likedAlbums': [
        for (final ids in snapshot['likedAlbums'] as List? ?? [])
          refs(ids, trackIds),
      ],
      'recent': refs(snapshot['recent'], trackIds),
      'retainedTrackIds': <String>{
        ...refs(snapshot['retainedTrackIds'], trackIds),
        // Downloaded albums must stay in the library after device paths vanish.
        for (final row in snapshot['tracks'] as List)
          if (row['cachedPath'] != null || row['localPath'] != null)
            row['id'] as String,
      }.toList(),
      'trackMatchExcluded': refs(snapshot['trackMatchExcluded'], trackIds),
      'preferredTrackVariants': refs(
        snapshot['preferredTrackVariants'],
        trackIds,
      ),
      'trackPlayCounts': counts('trackPlayCounts', trackIds),
      'playlistPlayCounts': counts('playlistPlayCounts', playlistIds),
      'settings': settings,
    };
  }

  static Map<String, dynamic> _portableTrack(Track track) {
    final json = track.toJson();
    for (final key in [
      'localPath',
      'cachedPath',
      'artPath',
      'downloadedAt',
      'torrentLink',
    ]) {
      json.remove(key);
    }
    // URLs may contain private passkeys, credentials or refer to a local .torrent.
    // A public infohash is sufficient to rediscover the original torrent files.
    final hash = track.torrentHash;
    if (hash != null && RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(hash)) {
      json['torrentLink'] = 'magnet:?xt=urn:btih:${hash.toLowerCase()}';
    }
    return json;
  }

  static Map<String, dynamic> _portableSettings(
    Map settings,
    Set<String> tracks,
    Set<String> playlists,
  ) {
    final result = <String, dynamic>{};
    for (final key in [
      'autoCache',
      'autoplayRadio',
      'checkAppUpdates',
      'equalizerEnabled',
      'normalizeVolume',
      'monoAudio',
      'crossfadeEnabled',
    ]) {
      if (!settings.containsKey(key)) continue;
      if (settings[key] is! bool) {
        throw const FormatException('Повреждены настройки профиля.');
      }
      result[key] = settings[key];
    }
    for (final entry in {
      'volume': (0, 1),
      'cacheLimitMb': (64, 1048576),
      'metadataCacheMb': (32, 4096),
      'downloadConcurrency': (1, 6),
      'prefetchTracks': (0, 10),
      'crossfadeSeconds': (1, 12),
    }.entries) {
      final value = settings[entry.key];
      if (value == null) continue;
      if (value is! num ||
          !value.isFinite ||
          value < entry.value.$1 ||
          value > entry.value.$2 ||
          (!['volume', 'crossfadeSeconds'].contains(entry.key) &&
              value is! int)) {
        throw const FormatException('Повреждены настройки профиля.');
      }
      result[entry.key] = value;
    }
    for (final entry in {
      'language': ['ru', 'en'],
      'downloadQuality': ['original', 'lossless', 'compact'],
    }.entries) {
      if (!settings.containsKey(entry.key)) continue;
      if (!entry.value.contains(settings[entry.key])) {
        throw const FormatException('Повреждены настройки профиля.');
      }
      result[entry.key] = settings[entry.key];
    }
    if (settings.containsKey('equalizerGains')) {
      final gains = settings['equalizerGains'];
      if (gains is! List ||
          gains.length != 6 ||
          gains.any((v) => v is! num || !v.isFinite || v < -12 || v > 12)) {
        throw const FormatException('Повреждены настройки профиля.');
      }
      result['equalizerGains'] = List<num>.from(gains);
    }
    if (settings['playback'] case final Map session) {
      final original = List<String>.from(
        session['originalIds'] as List? ?? session['ids'] as List? ?? [],
      );
      // Old sessions can refer to tracks removed since the last playback save.
      // The player already drops those references when restoring a queue.
      final clean = <String, dynamic>{'originalIds': original};
      for (final key in ['order', 'unshuffledOrder', 'radioEntries']) {
        final order = List<int>.from(
          session[key] as List? ??
              (key == 'order' ? List.generate(original.length, (i) => i) : []),
        );
        if (order.any((i) => i < 0 || i >= original.length) ||
            order.toSet().length != order.length) {
          throw const FormatException('Повреждена очередь профиля.');
        }
        clean[key] = order;
      }
      final position = session['position'] ?? 0;
      final index = session['index'] ?? 0;
      if (position is! int ||
          position < 0 ||
          index is! int ||
          index < -1 ||
          (session['shuffle'] != null && session['shuffle'] is! bool) ||
          !['off', 'all', 'one'].contains(session['repeat'] ?? 'off')) {
        throw const FormatException('Повреждена очередь профиля.');
      }
      clean.addAll({
        'position': position,
        'index': index,
        'shuffle': session['shuffle'] ?? false,
        'repeat': session['repeat'] ?? 'off',
      });
      final context = session['contextPlaylistId'];
      if (context is String &&
          (playlists.contains(context) ||
              context == MusicPlaylist.deviceTop50Id)) {
        clean['contextPlaylistId'] = context;
      }
      result['playback'] = clean;
    } else if (settings['playback'] != null) {
      throw const FormatException('Повреждена очередь профиля.');
    }
    return result;
  }

  /// Current device records win conflicts; additions keep their original order.
  /// Counts use max so importing the same file twice never doubles statistics.
  Map<String, dynamic> merge(
    Map<String, dynamic> current, {
    bool includeSettings = true,
  }) {
    final incoming = _profile;
    final result = Map<String, dynamic>.from(current);
    final tracks = {
      for (final row in current['tracks'] as List) row['id'] as String: row,
    };
    for (final row in incoming['tracks'] as List) {
      tracks.putIfAbsent(row['id'] as String, () => row);
    }
    result['tracks'] = tracks.values.toList();
    final playlists = {
      for (final row in current['playlists'] as List) row['id'] as String: row,
    };
    for (final row in incoming['playlists'] as List) {
      final old = playlists[row['id']];
      playlists[row['id'] as String] = old == null
          ? row
          : {
              ...Map<String, dynamic>.from(old as Map),
              'trackIds': [
                ...old['trackIds'] as List,
                ...<String>{
                  ...List<String>.from(row['trackIds'] as List),
                }.difference(
                  List<String>.from(old['trackIds'] as List).toSet(),
                ),
              ],
            };
    }
    result['playlists'] = playlists.values.toList();
    for (final key in [
      'liked',
      'likedPlaylists',
      'retainedTrackIds',
      'trackMatchExcluded',
      'preferredTrackVariants',
    ]) {
      result[key] = <String>{
        ...List<String>.from(current[key] as List),
        ...List<String>.from(incoming[key] as List),
      }.toList();
    }
    final albums = [
      for (final ids in current['likedAlbums'] as List)
        List<String>.from(ids as List),
    ];
    for (final ids in incoming['likedAlbums'] as List) {
      final added = List<String>.from(ids as List);
      if (!albums.any((old) => old.toSet().containsAll(added))) {
        albums.removeWhere((old) => added.toSet().containsAll(old));
        albums.add(added);
      }
    }
    result['likedAlbums'] = albums;
    result['recent'] = <String>{
      ...List<String>.from(current['recent'] as List),
      ...List<String>.from(incoming['recent'] as List),
    }.take(100).toList();
    for (final key in ['trackPlayCounts', 'playlistPlayCounts']) {
      final counts = Map<String, int>.from(current[key] as Map);
      for (final entry in Map<String, int>.from(incoming[key] as Map).entries) {
        counts[entry.key] = math.max(counts[entry.key] ?? 0, entry.value);
      }
      result[key] = counts;
    }
    final settings = Map<String, dynamic>.from(current['settings'] as Map);
    if (includeSettings) {
      final portable = Map<String, dynamic>.from(incoming['settings'] as Map);
      final session = settings['playback'];
      if (session is Map &&
          (session['originalIds'] as List? ?? session['ids'] as List? ?? [])
              .isNotEmpty) {
        portable.remove('playback');
      }
      settings.addAll(portable);
    }
    result['settings'] = settings;
    return result;
  }
}
