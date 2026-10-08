import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import '../data/library_repository.dart';
import '../data/torrent_service.dart';
import '../domain/models.dart';

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
  Future<void> close();
}

class NativeAudioBackend extends AudioBackend {
  NativeAudioBackend() {
    for (final stream in [
      player.stream.playing,
      player.stream.buffering,
      player.stream.position,
      player.stream.duration,
      player.stream.volume,
    ]) {
      _subscriptions.add(stream.listen((_) => notifyListeners()));
    }
  }
  final Player player = Player(
    configuration: const PlayerConfiguration(title: 'Mumpa'),
  );
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
  double get volume => player.state.volume / 100;
  @override
  Stream<void> get completed =>
      player.stream.completed.where((value) => value).map((_) {});
  @override
  Stream<String> get errors => player.stream.error;
  @override
  Future<void> open(String uri, {bool play = true}) =>
      player.open(Media(uri), play: play);
  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> stop() => player.stop();
  @override
  Future<void> seek(Duration value) => player.seek(value);
  @override
  Future<void> setVolume(double value) => player.setVolume(value * 100);
  @override
  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
    dispose();
  }
}

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.library,
    required this.torrents,
    required this.backend,
  }) {
    backend.addListener(_onBackend);
    _completeSubscription = backend.completed.listen((_) {
      unawaited(next(automatic: true));
    });
    _errorSubscription = backend.errors.listen((message) {
      error = message.contains('Failed to open')
          ? 'Поток недоступен. Проверьте подключение и наличие сидов; можно выбрать другой источник.'
          : message;
      loading = false;
      _openedId = null;
      unawaited(backend.stop());
      system?.publish();
      notifyListeners();
    });
  }
  final LibraryRepository library;
  final TorrentService torrents;
  final AudioBackend backend;
  late final StreamSubscription<void> _completeSubscription;
  late final StreamSubscription<String> _errorSubscription;
  AudioSession? _session;
  final List<StreamSubscription<dynamic>> _sessionSubscriptions = [];
  SystemAudioHandler? system;
  List<Track> _original = [];
  List<int> _order = [];
  int _cursor = -1;
  int _request = 0;
  bool loading = false, shuffle = false;
  PlayerRepeatMode repeat = PlayerRepeatMode.off;
  String? error;
  DateTime _lastSave = DateTime.now();
  Timer? _sleep;
  DateTime? sleepUntil;
  bool _wasPlaying = false;
  List<Track> get queue => List.unmodifiable(
    _order.map((i) => library.byId(_original[i].id) ?? _original[i]),
  );
  int get index => _cursor;
  Track? get current => _cursor >= 0 && _cursor < _order.length
      ? library.byId(_original[_order[_cursor]].id) ??
            _original[_order[_cursor]]
      : null;
  bool get playing => backend.playing;
  bool get stopped => _openedId == null && !loading;
  bool get buffering => loading || backend.buffering;
  Duration get position => backend.position;
  Duration get duration => backend.duration > Duration.zero
      ? backend.duration
      : current?.duration ?? Duration.zero;
  double get volume => backend.volume;

  Future<void> initialize({bool platformAudio = true}) async {
    if (platformAudio && Platform.isAndroid) {
      system = await AudioService.init(
        builder: () => SystemAudioHandler(this),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'app.mumpa.playback',
          androidNotificationChannelName: 'Музыка',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
        ),
      );
      _session = await AudioSession.instance;
      await _session!.configure(const AudioSessionConfiguration.music());
      _sessionSubscriptions.add(
        _session!.becomingNoisyEventStream.listen((_) => unawaited(pause())),
      );
      _sessionSubscriptions.add(
        _session!.interruptionEventStream.listen((event) {
          if (event.begin) {
            _wasPlaying = playing;
            unawaited(pause());
          } else if (_wasPlaying &&
              event.type != AudioInterruptionType.unknown) {
            _wasPlaying = false;
            unawaited(play());
          }
        }),
      );
    }
    await backend.setVolume(
      (library.settings['volume'] as num?)?.toDouble() ?? 0.8,
    );
    final session = library.settings['playback'];
    if (session is Map) {
      final ids = List<String>.from(session['ids'] as List? ?? []);
      _original = ids.map(library.byId).whereType<Track>().toList();
      _order = List.generate(_original.length, (i) => i);
      _cursor = (session['index'] as int? ?? 0).clamp(
        0,
        (_original.length - 1).clamp(0, 1000000),
      );
      repeat = PlayerRepeatMode.values.byName(
        session['repeat'] as String? ?? 'off',
      );
      // Restore UI and queue, but do not start a network transfer until play.
      if (_original.isEmpty) _cursor = -1;
      _restorePosition = Duration(
        milliseconds: (session['position'] as num?)?.toInt() ?? 0,
      );
      _openedId = null;
      _publishQueue();
      notifyListeners();
    }
  }

  Duration? _restorePosition;
  String? _openedId;
  void _onBackend() {
    system?.publish();
    notifyListeners();
    if (DateTime.now().difference(_lastSave).inSeconds >= 5 &&
        current != null) {
      _lastSave = DateTime.now();
      unawaited(saveSession());
    }
  }

  Future<void> saveSession() => library.setSetting('playback', {
    'ids': queue.map((t) => t.id).toList(),
    'index': _cursor,
    'position': position.inMilliseconds,
    'repeat': repeat.name,
  });

  Future<void> playTracks(List<Track> tracks, {int index = 0}) async {
    if (tracks.isEmpty) return;
    _original = List.of(tracks);
    _order = List.generate(tracks.length, (i) => i);
    _cursor = index.clamp(0, tracks.length - 1);
    if (shuffle) _shuffleKeepingCurrent();
    _publishQueue();
    await _open();
  }

  Future<String> resolve(Track track) async {
    for (final path in [track.cachedPath, track.localPath]) {
      if (path != null && await File(path).exists()) {
        return Uri.file(path).toString();
      }
    }
    if (track.source == TrackSource.torrent) {
      return (await torrents.resolve(track)).toString();
    }
    throw FileSystemException(
      'Файл перемещён или удалён. Импортируйте его снова.',
      track.localPath,
    );
  }

  Future<void> _open({bool play = true}) async {
    final track = current;
    if (track == null) return;
    final request = ++_request;
    loading = true;
    error = null;
    _openedId = null;
    notifyListeners();
    system?.publish();
    try {
      // Stop the previous decoder before a potentially long metadata/network wait.
      await backend.stop();
      final uri = await resolve(track);
      if (request != _request) return;
      if (play && _session != null && !await _session!.setActive(true)) {
        throw StateError('Аудиофокус занят другим приложением.');
      }
      await backend.open(uri, play: play);
      if (request != _request) return;
      _openedId = track.id;
      if (_restorePosition != null) {
        await backend.seek(_restorePosition!);
        _restorePosition = null;
      }
      await library.markPlayed(track.id);
      await saveSession();
    } catch (e) {
      if (request == _request) {
        error = e.toString();
        await backend.pause();
      }
    } finally {
      if (request == _request) {
        loading = false;
        _publishQueue();
        notifyListeners();
        system?.publish();
      }
    }
  }

  Future<void> play() async {
    if (current == null) return;
    if (_openedId != current!.id) {
      await _open();
      return;
    }
    if (_session != null && !await _session!.setActive(true)) return;
    await backend.play();
  }

  Future<void> pause() async {
    if (buffering) {
      await stop();
    } else {
      await backend.pause();
    }
    await saveSession();
  }

  Future<void> toggle() => playing || buffering ? pause() : play();
  Future<void> stop() async {
    ++_request;
    loading = false;
    await backend.stop();
    _openedId = null;
    await _session?.setActive(false);
    notifyListeners();
    system?.publish();
  }

  Future<void> seek(Duration value) async {
    if (_openedId == null) {
      _restorePosition = value;
      notifyListeners();
      return;
    }
    await backend.seek(value);
    await saveSession();
  }

  Future<void> next({bool automatic = false}) async {
    if (automatic && repeat == PlayerRepeatMode.one) {
      await _open();
      return;
    }
    if (_cursor + 1 < _order.length) {
      _cursor++;
    } else if (repeat == PlayerRepeatMode.all && _order.isNotEmpty) {
      _cursor = 0;
    } else {
      await backend.pause();
      await saveSession();
      return;
    }
    _restorePosition = null;
    await _open();
  }

  Future<void> previous() async {
    if (position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    if (_cursor > 0) {
      _cursor--;
    } else if (repeat == PlayerRepeatMode.all && _order.isNotEmpty) {
      _cursor = _order.length - 1;
    }
    _restorePosition = null;
    await _open();
  }

  Future<void> jump(int index) async {
    if (index < 0 || index >= _order.length) return;
    _cursor = index;
    _restorePosition = null;
    await _open();
  }

  void enqueue(Track track, {bool next = false}) {
    _original.add(track);
    if (next && _cursor >= 0) {
      _order.insert(_cursor + 1, _original.length - 1);
    } else {
      _order.add(_original.length - 1);
    }
    _publishQueue();
    notifyListeners();
    unawaited(saveSession());
  }

  Future<void> removeQueue(int index) async {
    if (index < 0 || index >= _order.length) return;
    final active = index == _cursor;
    _order.removeAt(index);
    if (index < _cursor || _cursor == _order.length) _cursor--;
    _publishQueue();
    notifyListeners();
    if (active) {
      if (_cursor >= 0) {
        await _open();
      } else {
        await stop();
      }
    }
    await saveSession();
  }

  void _shuffleKeepingCurrent() {
    if (_cursor < 0) {
      _order.shuffle(Random());
      return;
    }
    final current = _order.removeAt(_cursor);
    _order.shuffle(Random());
    _order.insert(0, current);
    _cursor = 0;
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    if (shuffle) {
      _shuffleKeepingCurrent();
    } else {
      final current = _cursor >= 0 ? _order[_cursor] : null;
      _order.sort();
      _cursor = current != null ? _order.indexOf(current) : -1;
    }
    _publishQueue();
    notifyListeners();
    unawaited(saveSession());
  }

  void cycleRepeat() {
    setRepeat(PlayerRepeatMode.values[(repeat.index + 1) % 3]);
  }

  void setRepeat(PlayerRepeatMode value) {
    repeat = value;
    notifyListeners();
    system?.publish();
    unawaited(saveSession());
  }

  Future<void> setVolume(double value) async {
    await backend.setVolume(value);
    await library.setSetting('volume', value);
  }

  void setSleep(Duration? time) {
    _sleep?.cancel();
    sleepUntil = time == null ? null : DateTime.now().add(time);
    if (time != null) {
      _sleep = Timer(time, () {
        sleepUntil = null;
        unawaited(pause());
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void _publishQueue() {
    system?.queue.add(
      queue
          .map(
            (t) => MediaItem(
              id: t.id,
              title: t.title,
              artist: t.artist,
              album: t.album,
              duration: t.durationMs > 0 ? t.duration : null,
              artUri: t.artPath != null ? Uri.file(t.artPath!) : null,
            ),
          )
          .toList(),
    );
    system?.publish();
  }

  Future<void> close() async {
    _sleep?.cancel();
    await saveSession();
    await _completeSubscription.cancel();
    await _errorSubscription.cancel();
    for (final subscription in _sessionSubscriptions) {
      await subscription.cancel();
    }
    backend.removeListener(_onBackend);
    await backend.close();
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
