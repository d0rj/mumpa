part of 'playback_controller.dart';

abstract class AudioBackend extends ChangeNotifier {
  bool get playing;
  bool get buffering;
  Duration get position;
  Duration get duration;
  double get volume;
  Stream<void> get completed;
  Stream<String> get errors;
  Future<void> open(String uri, {bool play = true});
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
  Future<void> open(String uri, {bool play = true}) async {
    await cancelPrepared();
    await _finishFade();
    final native = player.platform;
    if (native is NativePlayer) {
      // media_kit defaults to five seconds. A cold torrent often needs longer
      // for peer discovery before TorrServer can send its first audio bytes.
      await native.setProperty('network-timeout', '60');
    }
    await player.open(Media(uri), play: play);
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
  void publish() {
    final c = controller;
    final track = c.current;
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
