import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/download_repository.dart';
import '../data/library_repository.dart';
import '../data/source_operation.dart';
import '../domain/audio_preferences.dart';
import '../domain/models.dart';
import '../domain/music_metadata.dart';
import '../logic/app_controller.dart';
import 'mcp_server.dart';

part 'mcp_library.dart';
part 'mcp_sources.dart';

const _id = {'type': 'string', 'minLength': 1, 'maxLength': 256};
const _text = {'type': 'string', 'minLength': 1, 'maxLength': 512};
const _bool = {'type': 'boolean'};
const _offset = {'type': 'integer', 'minimum': 0, 'maximum': 1000000000};
const _pageFields = {
  'offset': _offset,
  'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100, 'default': 25},
};
const _ids = {'type': 'array', 'items': _id, 'minItems': 1, 'maxItems': 200};
const _volume = {'type': 'number', 'minimum': 0, 'maximum': 1};

Json _choice(List<String> values) => {
  'type': 'string',
  'enum': values,
  'maxLength': 64,
};
String _str(Json args, String key) => (args[key] as String).trim();
List<String> _strings(Json args, String key) =>
    (args[key] as List).cast<String>();
Never _invalid(String message) => throw McpError('invalid_argument', message);
Never _missing(String message) => throw McpError('not_found', message);

Json _page<T>(Iterable<T> items, Json args, Object? Function(T) encode) {
  final offset = args['offset'] as int? ?? 0;
  final limit = args['limit'] as int? ?? 25;
  final page = items.skip(offset).take(limit + 1).toList();
  return {
    'items': page.take(limit).map(encode).toList(),
    'next_offset': page.length > limit ? offset + limit : null,
  };
}

class MumpaMcp {
  MumpaMcp(this.app, {this.listenPort = port});

  static const port = 37145;
  static const endpoint = 'http://127.0.0.1:$port/mcp';
  static const _setting = 'mcpAccessKey';
  final AppController app;
  final int listenPort;
  final _random = Random.secure();
  final _operations = <String, _McpOperation>{};
  final _references = <String, ({Object value, DateTime expires})>{};
  McpServer? _server;
  Future<void> _transition = Future.value();
  bool _closed = false;

  LibraryRepository get _library => app.library;
  bool get enabled => _server != null;
  bool get configured => _library.settings[_setting] is String;
  String? get accessKey => _server?.token;
  Uri? get url {
    final activePort = _server?.port;
    return activePort == null
        ? null
        : Uri.parse('http://127.0.0.1:$activePort/mcp');
  }

  String _newKey(int bytes) => base64Url
      .encode(List.generate(bytes, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  Future<void> restore() async {
    final token = _library.settings[_setting];
    if (token is String && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      await _change(() => _start(token));
    }
  }

  Future<void> setEnabled(bool value) => _change(() async {
    if (value ? enabled : !configured && !enabled) return;
    if (value) {
      final token = _newKey(32);
      await _start(token);
      try {
        await _library.setSetting(_setting, token);
      } catch (_) {
        await _stop();
        rethrow;
      }
    } else {
      await _stop();
      await _library.setSetting(_setting, null);
    }
  });

  Future<void> _change(Future<void> Function() change) {
    final next = _transition.then((_) async {
      if (!_closed) await change();
    });
    _transition = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _start(String token) async {
    if (_server != null) return;
    final server = McpServer(token, _tools);
    await server.start(listenPort);
    _server = server;
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    for (final job in _operations.values) {
      job.cancellation.cancel();
    }
    await server?.close();
    await Future.wait([for (final job in _operations.values) job.completion]);
    _operations.clear();
    _references.clear();
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= () async {
    _closed = true;
    await _transition;
    await _stop();
  }();

  late final _tools = [
    McpTool(
      'state',
      'Read live playback, current track, queue revision, and download summary. Use queue for its entries.',
      (_) => {
        ..._playerState(),
        'download_jobs': app.downloads.jobs.length,
        'source_provider': app.searchProvider,
      },
      readOnly: true,
    ),
    McpTool(
      'queue',
      'Read the live queue, including occurrence IDs for duplicates. Pass next_offset to get the next page.',
      _queue,
      properties: _pageFields,
      readOnly: true,
    ),
    McpTool(
      'play',
      'Replace the queue and start playback. Supply exactly one of track_ids, album_id or playlist_id. '
          'Track IDs select exact versions. Album and playlist playback use Mumpa’s preferred versions. '
          'Poll mumpa_state for loading and playback outcome.',
      _play,
      properties: {
        'track_ids': _ids,
        'album_id': _id,
        'playlist_id': _id,
        'start_track_id': _id,
      },
      network: true,
      destructive: true,
    ),
    McpTool(
      'transport',
      'Resume, pause, stop, skip or seek the current queue. A skip or resume may buffer. '
          'Seek uses milliseconds and requires position_ms. Read mumpa_state for the latest state.',
      _transport,
      properties: {
        'action': _choice([
          'resume',
          'pause',
          'stop',
          'next',
          'previous',
          'seek',
        ]),
        'position_ms': _offset,
      },
      required: ['action'],
      network: true,
    ),
    McpTool(
      'player_options',
      'Set any combination of volume (0–1), shuffle, repeat, radio, and sleep timer. Use sleep_minutes=0 to clear the timer.',
      _playerOptions,
      properties: {
        'volume': _volume,
        'shuffle': _bool,
        'repeat': _choice(['off', 'all', 'one']),
        'radio': _bool,
        'sleep_minutes': {'type': 'integer', 'minimum': 0, 'maximum': 1440},
      },
    ),
    McpTool(
      'audio',
      'Read or update audio effects. EQ gains are six values in dB at the returned frequency bands. '
          'Use a preset or gains_db. crossfade_seconds=0 turns crossfade off.',
      _audio,
      properties: {
        'equalizer': _bool,
        'gains_db': {
          'type': 'array',
          'items': {'type': 'number', 'minimum': -12, 'maximum': 12},
          'minItems': 6,
          'maxItems': 6,
        },
        'preset': _choice(AudioPreferences.presets.keys.toList()),
        'normalize': _bool,
        'mono': _bool,
        'crossfade_seconds': {'type': 'integer', 'minimum': 0, 'maximum': 12},
      },
      idempotent: true,
    ),
    McpTool(
      'queue_add',
      'Append exact track IDs in order or insert them after the current occurrence. Duplicates are intentional.',
      _addQueue,
      properties: {
        'track_ids': _ids,
        'placement': _choice(['end', 'next']),
      },
      required: ['track_ids'],
    ),
    McpTool(
      'queue_edit',
      'Play, move or remove one queue occurrence. Use entry_id and revision from mumpa_queue. '
          'Move requires a zero-based final to_index. On stale_queue, read the queue again.',
      _editQueue,
      properties: {
        'action': _choice(['jump', 'move', 'remove']),
        'entry_id': _offset,
        'revision': _offset,
        'to_index': _offset,
      },
      required: ['action', 'entry_id', 'revision'],
      network: true,
      destructive: true,
    ),
    ..._libraryTools,
    ..._sourceTools,
  ];

  Track _track(String id) =>
      _library.byId(id) ?? _missing('Track ID is unknown. Search the library.');
  Album _album(String id) =>
      _library.albumById(id) ??
      _missing('Album ID is unknown. Search the library.');
  MusicPlaylist _playlist(String id) =>
      _library.playlistById(id) ??
      _missing('Playlist ID is unknown. Search the library.');

  Json _trackJson(Track item) => {
    'id': item.id,
    'title': item.title,
    'artist': item.artist,
    'album': item.album,
    'album_id': item.albumKey,
    'duration_ms': item.durationMs,
    'source': item.source.name,
    'format': item.format,
    'offline': item.offline,
    'liked': _library.isTrackLiked(item.id),
    if (item.year != null) 'year': item.year,
  };

  Json _playerState() {
    final player = app.playback;
    final current = player.current;
    return {
      'state': player.error != null
          ? 'error'
          : player.buffering
          ? 'buffering'
          : player.playing
          ? 'playing'
          : player.stopped
          ? 'stopped'
          : 'paused',
      'current': current == null ? null : _trackJson(current),
      'position_ms': player.position.inMilliseconds,
      'duration_ms': player.duration.inMilliseconds,
      'queue_index': player.index < 0 ? null : player.index,
      'queue_revision': player.queueRevision,
      'playlist_id': player.contextPlaylistId,
      'volume': player.volume,
      'shuffle': player.shuffle,
      'repeat': player.repeat.name,
      'radio': player.radioEnabled,
      'sleep_until': player.sleepUntil?.toUtc().toIso8601String(),
    };
  }

  Json _queue(Json args) {
    final player = app.playback;
    final tracks = player.queue, keys = player.queueEntryKeys;
    return {
      'revision': player.queueRevision,
      'total': tracks.length,
      ..._page(
        Iterable<int>.generate(tracks.length),
        args,
        (i) => {
          'index': i,
          'entry_id': keys[i],
          'current': i == player.index,
          'radio': player.isRadioEntry(i),
          'track': _trackJson(tracks[i]),
        },
      ),
    };
  }

  Json _play(Json args) {
    if ([
          'track_ids',
          'album_id',
          'playlist_id',
        ].where(args.containsKey).length !=
        1) {
      _invalid('Supply exactly one of track_ids, album_id or playlist_id.');
    }
    final playlist = args.containsKey('playlist_id')
        ? _playlist(_str(args, 'playlist_id'))
        : null;
    final exact = args.containsKey('track_ids');
    final tracks = exact
        ? _strings(args, 'track_ids').map(_track).toList()
        : playlist != null
        ? playlist.trackIds.map(_library.byId).whereType<Track>().toList()
        : _album(_str(args, 'album_id')).tracks;
    if (tracks.isEmpty) {
      throw const McpError(
        'empty_collection',
        'This collection has no playable tracks.',
      );
    }
    final start = args['start_track_id'] as String?;
    final index = start == null
        ? 0
        : tracks.indexWhere((track) => track.id == start);
    if (index < 0) {
      _invalid('start_track_id must belong to the selected tracks.');
    }
    app.cancelPendingCollectionPlayback();
    _startPlayback(
      exact
          ? app.playback.playTracks(tracks, index: index)
          : app.playCollection(
              tracks,
              index: index,
              playlistId: playlist?.id,
              selectedVariant: start == null ? null : tracks[index],
            ),
    );
    return {
      'accepted': true,
      'requested_track': _trackJson(tracks[index]),
      'requested_count': tracks.length,
    };
  }

  void _startPlayback(Future<void> pending) {
    unawaited(
      pending.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          debugPrint('Mumpa MCP: playback command failed.');
        },
      ),
    );
  }

  Future<Json> _transport(Json args) async {
    final player = app.playback;
    final action = args['action'];
    if ((action == 'seek') != args.containsKey('position_ms')) {
      _invalid('position_ms is required only for seek.');
    }
    app.cancelPendingCollectionPlayback();
    if (!player.hasQueue && action != 'pause' && action != 'stop') {
      throw const McpError('empty_queue', 'Start or enqueue tracks first.');
    }
    switch (action) {
      case 'resume':
        _startPlayback(player.play());
      case 'pause':
        await player.pause();
      case 'stop':
        await player.stop();
      case 'next':
        _startPlayback(player.next());
      case 'previous':
        _startPlayback(player.previous());
      case 'seek':
        await player.seek(Duration(milliseconds: args['position_ms'] as int));
    }
    return {'accepted': true, ..._playerState()};
  }

  Future<Json> _playerOptions(Json args) async {
    if (args.isEmpty) _invalid('Supply at least one player option.');
    final player = app.playback;
    if (args['shuffle'] case bool shuffle when shuffle != player.shuffle) {
      player.toggleShuffle();
    }
    if (args['repeat'] case String repeat when repeat != player.repeat.name) {
      player.setRepeat(PlayerRepeatMode.values.byName(repeat));
    }
    if (args['sleep_minutes'] case int minutes) {
      player.setSleep(minutes == 0 ? null : Duration(minutes: minutes));
    }
    if (args['radio'] case bool enabled when enabled != player.radioEnabled) {
      await player.setRadioEnabled(enabled);
    }
    if (args['volume'] case num volume) {
      await player.setVolume(volume.toDouble());
    }
    await _library.flush();
    return _playerState();
  }

  Future<Json> _addQueue(Json args) async {
    final player = app.playback;
    final tracks = _strings(args, 'track_ids').map(_track).toList();
    player.enqueueTracks(tracks, next: args['placement'] == 'next');
    await _library.flush();
    return {'added': tracks.length, ..._playerState()};
  }

  Future<Json> _audio(Json args) async {
    if (args.containsKey('preset') && args.containsKey('gains_db')) {
      _invalid('Choose preset or gains_db.');
    }
    final player = app.playback;
    final gains = args['preset'] == null
        ? args['gains_db']
        : AudioPreferences.presets[args['preset']];
    final crossfade = args['crossfade_seconds'] as int?;
    final settings = <String, Object>{
      'equalizerGains': ?gains,
      if (args['equalizer'] case final bool value) 'equalizerEnabled': value,
      if (args['normalize'] case final bool value) 'normalizeVolume': value,
      if (args['mono'] case final bool value) 'monoAudio': value,
      if (crossfade != null && crossfade > 0) 'crossfadeSeconds': crossfade,
      if (crossfade != null) 'crossfadeEnabled': crossfade > 0,
    };
    for (final setting in settings.entries) {
      await player.setAudioSetting(setting.key, setting.value);
    }
    final options = player.audioPreferences;
    return {
      'equalizer': options.equalizerEnabled,
      'bands_hz': AudioPreferences.frequencies,
      'gains_db': options.gains,
      'preset': options.preset,
      'normalize': options.normalize,
      'mono': options.mono,
      'crossfade_seconds': options.crossfadeSeconds,
    };
  }

  Future<Json> _editQueue(Json args) async {
    final player = app.playback;
    if (args['revision'] != player.queueRevision) {
      throw const McpError(
        'stale_queue',
        'Read mumpa_queue again before editing.',
      );
    }
    final keys = player.queueEntryKeys;
    final index = keys.indexOf(args['entry_id'] as int);
    if (index < 0) {
      _missing('Queue occurrence is unknown. Read mumpa_queue again.');
    }
    if ((args['action'] == 'move') != args.containsKey('to_index')) {
      _invalid('to_index is required only for move.');
    }
    switch (args['action']) {
      case 'jump':
        app.cancelPendingCollectionPlayback();
        _startPlayback(player.jump(index));
      case 'move':
        final to = args['to_index'] as int;
        if (to >= keys.length) _invalid('to_index is outside the queue.');
        await player.moveQueue(index, to);
      case 'remove':
        if (index == player.index) {
          _startPlayback(player.removeQueue(index));
        } else {
          await player.removeQueue(index);
        }
    }
    return {'accepted': true, ..._playerState()};
  }
}
