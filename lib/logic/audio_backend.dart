part of 'playback_controller.dart';

abstract class AudioBackend extends ChangeNotifier {
  bool get playing;
  bool get buffering;
  Duration get position;
  Duration get duration;
  double get volume;
  Stream<void> get completed;
  Stream<String> get errors;

  /// Apply [start] while loading, before playback or an explicit seek is ready.
  Future<void> open(
    String uri, {
    bool play = true,
    Duration start = Duration.zero,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration value);
  Future<void> setVolume(double value);
  Future<void> applyPreferences(AudioPreferences preferences) async {}
  bool get supportsCrossfade => false;
  bool get transitioning => false;
  Future<bool> prepareNext(String uri) async => false;
  Future<void> cancelPrepared() async {}
  Future<bool> crossfade(Duration duration, bool Function() onStarted) async =>
      false;
  Future<void> close();
}

class NativeAudioBackend extends AudioBackend {
  NativeAudioBackend() {
    _bind();
  }
  void _bind() {
    for (final stream in [
      player.stream.playing,
      player.stream.buffering,
      player.stream.position,
      player.stream.duration,
      player.stream.volume,
    ]) {
      _subscriptions.add(stream.listen((_) => notifyListeners()));
    }
    _subscriptions.add(
      player.stream.completed.listen((v) {
        if (v) _completed.add(null);
      }),
    );
    _subscriptions.add(player.stream.error.listen(_errors.add));
  }

  Player player = Player(
    configuration: const PlayerConfiguration(title: 'Mumpa'),
  );
  Player? _spare, _tail;
  String? _preparedUri;
  int _prepareIntent = 0;
  double _volume = .8, _fadeFraction = 1;
  bool _closed = false;
  Timer? _fadeTimer;
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<String>.broadcast();
  AudioPreferences _preferences = AudioPreferences();
  final _configuredGraphs = <Player, String>{};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  @override
  bool get playing => player.state.playing;
  @override
  bool get buffering => player.state.buffering;
  @override
  Duration get position => player.state.position;
  @override
  Duration get duration => player.state.duration;
  @override
  double get volume => _volume;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  Future<void> open(
    String uri, {
    bool play = true,
    Duration start = Duration.zero,
  }) async {
    await cancelPrepared();
    await _finishFade();
    final native = player.platform;
    if (native is NativePlayer) {
      // media_kit defaults to five seconds. A cold torrent often needs longer
      // for peer discovery before TorrServer can send its first audio bytes.
      await native.setProperty('network-timeout', '60');
    }
    // open() only queues the native load. An immediate seek can be discarded
    // before file-loaded; Media.start is applied by libmpv's on-load hook.
    await player.open(Media(uri, start: start), play: play);
  }

  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() async {
    // The outgoing tail ends at Pause; resume keeps the incoming decoder/position.
    await _finishFade();
    await player.pause();
  }

  @override
  Future<void> stop() async {
    await cancelPrepared();
    await _finishFade();
    await player.stop();
  }

  @override
  Future<void> seek(Duration value) async {
    await _finishFade();
    await player.seek(value);
  }

  @override
  Future<void> setVolume(double value) async {
    _volume = value.clamp(0, 1);
    await _applyVolumes();
    notifyListeners();
  }

  Future<void> _applyVolumes() async {
    final volume = _volume * 100;
    await player.setVolume(volume * _fadeFraction);
    await _tail?.setVolume(volume * (1 - _fadeFraction));
  }

  Future<void> _configure(Player target) async {
    final native = target.platform;
    if (native is NativePlayer) {
      await native.setProperty('network-timeout', '60');
      final graph = _preferences.filterGraph;
      if (_configuredGraphs[target] != graph) {
        await native.setProperty('af', graph);
        _configuredGraphs[target] = graph;
      }
    }
  }

  @override
  Future<void> applyPreferences(AudioPreferences preferences) async {
    _preferences = preferences;
    await _configure(player);
    if (_spare != null) await _configure(_spare!);
    if (_tail != null) await _configure(_tail!);
    await _applyVolumes();
    if (preferences.crossfadeSeconds == 0) await _finishFade();
  }

  @override
  bool get supportsCrossfade => true;
  @override
  bool get transitioning => _tail != null;

  @override
  Future<bool> prepareNext(String uri) async {
    if (_closed || transitioning) return false;
    if (_preparedUri == uri) return true;
    final intent = ++_prepareIntent;
    final spare = _spare ??= Player(
      configuration: const PlayerConfiguration(title: 'Mumpa'),
    );
    try {
      await _configure(spare);
      await spare.setVolume(0);
      await spare
          .open(Media(uri), play: false)
          .timeout(const Duration(seconds: 8));
      if (spare.state.duration == Duration.zero) {
        await spare.stream.duration
            .firstWhere((v) => v > Duration.zero)
            .timeout(const Duration(seconds: 8));
      }
      if (_closed || intent != _prepareIntent) return false;
      _preparedUri = uri;
      return true;
    } catch (_) {
      if (intent == _prepareIntent) await cancelPrepared();
      return false; // An unavailable next file must never interrupt the current song.
    }
  }

  @override
  Future<void> cancelPrepared() async {
    ++_prepareIntent;
    _preparedUri = null;
    // A slow network open can hold the spare's decoder lock. It is muted and
    // its intent is invalid now; Pause/Stop must not wait for that lock.
    final spare = _spare;
    if (spare != null) {
      unawaited(spare.stop().catchError((Object _) {}));
    }
  }

  @override
  Future<bool> crossfade(Duration duration, bool Function() onStarted) async {
    final incoming = _spare;
    if (_preparedUri == null || incoming == null || transitioning || _closed) {
      return false;
    }
    final intent = _prepareIntent;
    try {
      await incoming.play();
      if (incoming.state.position == Duration.zero) {
        await incoming.stream.position
            .firstWhere((v) => v > Duration.zero)
            .timeout(const Duration(seconds: 3));
      }
      if (_closed || intent != _prepareIntent) return false;
      final outgoing = player;
      for (final s in _subscriptions) {
        await s.cancel();
      }
      _subscriptions.clear();
      player = incoming;
      _spare = null;
      _preparedUri = null;
      _tail = outgoing;
      _fadeFraction = 0;
      _bind();
      if (!onStarted()) {
        // Transport intent changed while the muted incoming decoder was opening.
        for (final s in _subscriptions) {
          await s.cancel();
        }
        _subscriptions.clear();
        player = outgoing;
        _tail = null;
        _spare = incoming;
        _fadeFraction = 1;
        _bind();
        await incoming.stop();
        return false;
      }
      final watch = Stopwatch()..start();
      var updating = false;
      _fadeTimer = Timer.periodic(const Duration(milliseconds: 40), (_) async {
        if (updating || _closed) return;
        updating = true;
        try {
          _fadeFraction = (watch.elapsedMicroseconds / duration.inMicroseconds)
              .clamp(0, 1);
          if (_fadeFraction >= 1) {
            await _finishFade();
          } else {
            await _applyVolumes();
          }
        } finally {
          updating = false;
        }
      });
      notifyListeners();
      return true;
    } catch (_) {
      await cancelPrepared();
      return false;
    }
  }

  Future<void> _finishFade() async {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _fadeFraction = 1;
    final tail = _tail;
    _tail = null;
    if (tail != null) {
      _configuredGraphs.remove(tail);
      await tail.dispose();
    }
    if (!_closed) {
      await player.setVolume(_volume * 100);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    ++_prepareIntent;
    await _finishFade();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
    await _spare?.dispose();
    await _completed.close();
    await _errors.close();
    dispose();
  }
}

class SystemAudioHandler extends BaseAudioHandler {
  SystemAudioHandler(this.controller);
  final PlaybackController controller;
  String? _lastDeviceState;
  MediaItem _item(Track track) => MediaItem(
    id: track.id,
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration: track.durationMs > 0 ? track.duration : null,
    playable: true,
  );
  List<Track> _tracks(String parent) {
    final library = controller.library;
    if (parent == 'liked') return library.favoriteTracks;
    if (parent == 'offline') {
      return library.mediaTracks.where((t) => t.offline).toList();
    }
    if (parent.startsWith('playlist:')) {
      return (library.playlistById(parent.substring(9))?.trackIds ?? [])
          .map(library.byId)
          .whereType<Track>()
          .toList();
    }
    if (parent.startsWith('album:')) {
      return library.mediaAlbums
              .where((a) => a.id == parent.substring(6))
              .firstOrNull
              ?.tracks ??
          [];
    }
    final track = library.byId(parent);
    return track == null ? [] : [track];
  }

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    final continuation = RegExp(
      r'^mumpa-page:(\d+):(.*)$',
    ).firstMatch(parentMediaId);
    final parent = continuation?[2] ?? parentMediaId;
    final library = controller.library;
    final List<MediaItem> items;
    if (parent == AudioService.browsableRootId) {
      items = [
        for (final entry in {
          'liked': 'Любимое',
          'offline': 'Офлайн',
          'playlists': 'Плейлисты',
          'albums': 'Альбомы',
        }.entries)
          MediaItem(id: entry.key, title: tr(entry.value), playable: false),
      ];
    } else if (parent == 'playlists') {
      items = [
        for (final list in [
          library.topTracksPlaylist,
          ...library.mediaPlaylists,
        ])
          MediaItem(
            id: 'playlist:${list.id}',
            title: list.name,
            playable: false,
          ),
      ];
    } else if (parent == 'albums') {
      items = [
        for (final album in library.mediaAlbums)
          MediaItem(
            id: 'album:${album.id}',
            title: album.title,
            artist: album.artist,
            playable: false,
          ),
      ];
    } else {
      items = _tracks(parent).map(_item).toList();
    }
    final page =
        (options?['android.media.browse.extra.PAGE'] as int? ??
                int.tryParse(continuation?[1] ?? '') ??
                0)
            .clamp(0, 100000);
    final size =
        (options?['android.media.browse.extra.PAGE_SIZE'] as int? ?? 200).clamp(
          1,
          200,
        );
    return [
      ...items.skip(page * size).take(size),
      if (options?['android.media.browse.extra.PAGE'] == null &&
          (page + 1) * size < items.length)
        MediaItem(
          id: 'mumpa-page:${page + 1}:$parent',
          title: tr('Ещё'),
          playable: false,
        ),
    ];
  }

  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final words = query
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return [];
    return controller.library.mediaTracks
        .where(
          (t) => words.every(
            '${t.artist} ${t.title} ${t.album}'.toLowerCase().contains,
          ),
        )
        .take(100)
        .map(_item)
        .toList();
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final selected = _tracks(mediaId);
    if (selected.isNotEmpty) {
      await controller.playTracks(
        selected,
        contextPlaylistId: mediaId.startsWith('playlist:')
            ? mediaId.substring(9)
            : null,
      );
    }
  }

  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final found = await search(query, extras);
    if (found.isNotEmpty) {
      await controller.playTracks(
        found
            .map((m) => controller.library.byId(m.id))
            .whereType<Track>()
            .toList(),
      );
    }
  }

  void publish() {
    final c = controller;
    final track = c.current;
    if (Platform.isAndroid) {
      final state =
          '${track?.id}/${track?.title}/${c.playing}/${c.library.mediaPlaylists.length}';
      if (_lastDeviceState != state) {
        _lastDeviceState = state;
        unawaited(
          const MethodChannel('app.mumpa/device')
              .invokeMethod<void>('publish', {
                'title': track?.title ?? 'Mumpa',
                'artist': track?.artist ?? '',
                'playing': c.playing,
                'shortcuts': [
                  for (final list in [
                    c.library.topTracksPlaylist,
                    ...c.library.mediaPlaylists,
                  ].take(4))
                    {'id': list.id, 'name': list.name},
                ],
              })
              .catchError((Object _) {}),
        );
      }
    }
    if (track != null) {
      mediaItem.add(
        MediaItem(
          id: track.id,
          title: track.title,
          artist: track.artist,
          album: track.album,
          duration: c.duration > Duration.zero ? c.duration : null,
          artUri: track.artPath != null ? Uri.file(track.artPath!) : null,
        ),
      );
    }
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          c.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: const {MediaAction.seek},
        processingState: c.current == null
            ? AudioProcessingState.idle
            : c.error != null
            ? AudioProcessingState.error
            : c.buffering
            ? AudioProcessingState.buffering
            : c.stopped
            ? AudioProcessingState.idle
            : AudioProcessingState.ready,
        playing: c.playing,
        updatePosition: c.position,
        queueIndex: c.index >= 0 ? c.index : null,
        repeatMode: switch (c.repeat) {
          PlayerRepeatMode.off => AudioServiceRepeatMode.none,
          PlayerRepeatMode.all => AudioServiceRepeatMode.all,
          PlayerRepeatMode.one => AudioServiceRepeatMode.one,
        },
        shuffleMode: c.shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        errorMessage: c.error,
      ),
    );
  }

  @override
  Future<void> play() => controller.play();
  @override
  Future<void> pause() => controller.pause();
  @override
  Future<void> stop() => controller.stop();
  @override
  Future<void> seek(Duration position) => controller.seek(position);
  @override
  Future<void> skipToNext() => controller.next();
  @override
  Future<void> skipToPrevious() => controller.previous();
  @override
  Future<void> skipToQueueItem(int index) => controller.jump(index);
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    controller.setRepeat(switch (repeatMode) {
      AudioServiceRepeatMode.one => PlayerRepeatMode.one,
      AudioServiceRepeatMode.none => PlayerRepeatMode.off,
      _ => PlayerRepeatMode.all,
    });
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (controller.shuffle != (shuffleMode != AudioServiceShuffleMode.none)) {
      controller.toggleShuffle();
    }
  }
}
