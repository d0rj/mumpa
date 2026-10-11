import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import '../data/library_repository.dart';
import '../data/torrent_service.dart';
import '../data/source_operation.dart';
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
  Future<void> open(String uri, {bool play = true}) async {
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
  /// Track rows need transport changes, not every position/volume tick.
  final trackState =
      ValueNotifier<({String? id, bool playing, bool buffering, bool stopped})>(
        (id: null, playing: false, buffering: false, stopped: true),
      );

  @override
  void notifyListeners() {
    trackState.value = (
      id: current?.id,
      playing: playing,
      buffering: buffering,
      stopped: stopped,
    );
    super.notifyListeners();
  }

  @override
  void dispose() {
    trackState.dispose();
    super.dispose();
  }

  PlaybackController({
    required this.library,
    required this.torrents,
    required this.backend,
    this.audioStartupTimeout = const Duration(seconds: 45),
    this.decoderStartupTimeout = const Duration(seconds: 15),
    this.torrentStatusInterval = const Duration(seconds: 3),
  }) {
    backend.addListener(_onBackend);
    _completeSubscription = backend.completed.listen((_) {
      if (loading || _openedId == null || _openedId != current?.id) return;
      unawaited(next(automatic: true));
    });
    _errorSubscription = backend.errors.listen((message) {
      if (_closed || current == null) return;
      _restorePosition = position;
      ++_request;
      _cancelConnection();
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
  final Duration audioStartupTimeout,
      decoderStartupTimeout,
      torrentStatusInterval;
  SourceOperation? _connection;
  Timer? _statisticsTimer, _decoderTimer;
  TorrentInfo? _torrentStatus;
  String? connectionStatus;
  Duration _initialPlaybackPosition = Duration.zero;
  late final StreamSubscription<void> _completeSubscription;
  late final StreamSubscription<String> _errorSubscription;
  AudioSession? _session;
  final List<StreamSubscription<dynamic>> _sessionSubscriptions = [];
  SystemAudioHandler? system;
  List<Track> _original = [];
  List<int> _order = [];
  List<int> _unshuffledOrder = [];
  int _cursor = -1;
  int _request = 0;
  bool loading = false, shuffle = false;
  bool _closed = false;
  Future<void>? _closing;
  String? _contextPlaylistId;
  String? get contextPlaylistId => _contextPlaylistId;
  PlayerRepeatMode repeat = PlayerRepeatMode.off;
  String? error;
  DateTime _lastSave = DateTime.now();
  Timer? _sleep;
  DateTime? sleepUntil;
  bool _wasPlaying = false;
  List<Track> get queue => List.unmodifiable(
    _order.map((i) => library.byId(_original[i].id) ?? _original[i]),
  );
  // A track can occur several times. Its original slot identifies the entry.
  List<int> get queueEntryKeys => List.unmodifiable(_order);
  int get index => _cursor;
  Track? get current => _cursor >= 0 && _cursor < _order.length
      ? library.byId(_original[_order[_cursor]].id) ??
            _original[_order[_cursor]]
      : null;
  bool get playing =>
      _openedId == current?.id && current != null && backend.playing;
  bool get stopped => _openedId == null && !loading;
  bool get buffering =>
      loading ||
      (_openedId == current?.id && current != null && backend.buffering);
  Duration get position => _openedId == current?.id && current != null
      ? backend.position
      : _restorePosition ?? Duration.zero;
  Duration get duration =>
      _openedId == current?.id &&
          current != null &&
          backend.duration > Duration.zero
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
      final ids = List<String>.from(
        session['originalIds'] as List? ?? session['ids'] as List? ?? [],
      );
      final remapped = <int, int>{};
      _original = [];
      for (var i = 0; i < ids.length; i++) {
        final track = library.byId(ids[i]);
        if (track != null) {
          remapped[i] = _original.length;
          _original.add(track);
        }
      }
      final order = session['order'] is List
          ? (session['order'] as List).whereType<int>().toList()
          : List.generate(ids.length, (i) => i);
      final savedIndex = (session['index'] as int? ?? 0).clamp(
        0,
        (order.length - 1).clamp(0, 1000000),
      );
      _order = [];
      final restoredEntries = <int>{};
      _cursor = -1;
      var beforeSelected = 0;
      for (var i = 0; i < order.length; i++) {
        final mapped = remapped[order[i]];
        if (mapped == null || !restoredEntries.add(mapped)) continue;
        if (i < savedIndex) beforeSelected++;
        if (i == savedIndex) _cursor = _order.length;
        _order.add(mapped);
      }
      final restoredSelection = _cursor >= 0;
      if (_cursor < 0 && _order.isNotEmpty) {
        _cursor = beforeSelected.clamp(0, _order.length - 1);
      }
      repeat =
          PlayerRepeatMode.values
              .where((mode) => mode.name == session['repeat'])
              .firstOrNull ??
          PlayerRepeatMode.off;
      shuffle = session['shuffle'] == true;
      final base = session['unshuffledOrder'] is List
          ? (session['unshuffledOrder'] as List).whereType<int>().toList()
          : shuffle
          ? (List<int>.of(order)..sort())
          : order;
      _unshuffledOrder = [];
      final baseEntries = <int>{};
      for (final entry in base) {
        final mapped = remapped[entry];
        if (mapped != null &&
            restoredEntries.contains(mapped) &&
            baseEntries.add(mapped)) {
          _unshuffledOrder.add(mapped);
        }
      }
      _unshuffledOrder.addAll(_order.where(baseEntries.add));
      _contextPlaylistId = session['contextPlaylistId'] as String?;
      // Restore UI and queue, but do not start a network transfer until play.
      _restorePosition = restoredSelection
          ? Duration(
              milliseconds: ((session['position'] as num?)?.toInt() ?? 0).clamp(
                0,
                1 << 53,
              ),
            )
          : Duration.zero;
      _openedId = null;
      _publishQueue();
      notifyListeners();
    }
  }

  Duration? _restorePosition;
  String? _openedId;
  void _onBackend() {
    if (_openedId == current?.id &&
        current != null &&
        backend.playing &&
        !backend.buffering &&
        backend.position != _initialPlaybackPosition) {
      _decoderTimer?.cancel();
      _decoderTimer = null;
    }
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
    'originalIds': _original.map((t) => t.id).toList(),
    'order': List<int>.of(_order),
    'unshuffledOrder': List<int>.of(_unshuffledOrder),
    'index': _cursor,
    'position': position.inMilliseconds,
    'repeat': repeat.name,
    'shuffle': shuffle,
    'contextPlaylistId': _contextPlaylistId,
  });

  Future<void> playTracks(
    List<Track> tracks, {
    int index = 0,
    String? contextPlaylistId,
  }) async {
    if (tracks.isEmpty || _closed) return;
    _restorePosition = null;
    _openedId = null;
    _contextPlaylistId = contextPlaylistId;
    _original = List.of(tracks);
    _order = List.generate(tracks.length, (i) => i);
    _unshuffledOrder = List.of(_order);
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
    if (_closed) return;
    final track = current;
    if (track == null) return;
    final request = ++_request;
    var awaitingAudio = false;
    _cancelConnection();
    final connection = _connection = SourceOperation();
    _torrentStatus = null;
    connectionStatus = track.source == TrackSource.torrent
        ? 'Подключаем раздачу…'
        : null;
    loading = true;
    error = null;
    _openedId = null;
    notifyListeners();
    system?.publish();
    try {
      // Stop the previous decoder before a potentially long metadata/network wait.
      await connection.wait(backend.stop()).timeout(decoderStartupTimeout);
      if (request != _request) return;
      final uri = await connection.wait(resolve(track));
      if (request != _request) return;
      if (track.source == TrackSource.torrent &&
          {'http', 'https'}.contains(Uri.parse(uri).scheme)) {
        connectionStatus = 'Ищем пиров и ждём первые аудиоданные…';
        notifyListeners();
        var polling = false;
        final audioWait = Stopwatch()..start();
        _statisticsTimer = Timer.periodic(torrentStatusInterval, (_) async {
          if (polling || request != _request || connection.cancelled) return;
          polling = true;
          try {
            final info = await torrents
                .get(track.torrentHash!)
                .timeout(const Duration(seconds: 3));
            if (request != _request || connection.cancelled) return;
            _torrentStatus = info;
            connectionStatus = info.peers == 0
                ? 'Ждём соединения с пирами · подключено: 0 · ${audioWait.elapsed.inSeconds}/${audioStartupTimeout.inSeconds} с'
                : 'Получаем аудиоданные · пиров: ${info.peers} · ${formatBytes(info.speed.round())}/с';
            notifyListeners();
          } catch (_) {
            // Diagnostics must not replace the actual stream result.
          } finally {
            polling = false;
          }
        });
        awaitingAudio = true;
        await torrents.waitForAudio(
          Uri.parse(uri),
          operation: connection,
          timeout: audioStartupTimeout,
        );
        if (request != _request) return;
        _statisticsTimer?.cancel();
        connectionStatus = 'Запускаем воспроизведение…';
        notifyListeners();
      }
      if (play && _session != null && !await _session!.setActive(true)) {
        throw StateError('Аудиофокус занят другим приложением.');
      }
      _initialPlaybackPosition = _restorePosition ?? Duration.zero;
      awaitingAudio = false;
      await connection
          .wait(backend.open(uri, play: false))
          .timeout(decoderStartupTimeout);
      if (request != _request) return;
      _openedId = track.id;
      if (_restorePosition != null) {
        final restored = _restorePosition!;
        _restorePosition = null;
        await backend.seek(restored);
      }
      if (request != _request) return;
      if (play) {
        await connection.wait(backend.play()).timeout(decoderStartupTimeout);
      }
      await library.markPlayed(track.id);
      if (request != _request) return;
      await saveSession();
      if (play) {
        _decoderTimer = Timer(decoderStartupTimeout, () {
          if (request != _request || _closed) return;
          if (backend.playing &&
              !backend.buffering &&
              backend.position != _initialPlaybackPosition) {
            return;
          }
          error =
              'Аудиоданные получены, но воспроизведение не началось. '
              'Повтори попытку или выбери другой источник.';
          unawaited(stop());
        });
      }
    } on SourceCancelled {
      // A newer track or Stop owns the state now.
    } on TimeoutException {
      if (request == _request) {
        final message = !awaitingAudio
            ? 'Не удалось запустить воспроизведение. Повтори попытку или выбери другой источник.'
            : _torrentStatus?.peers == 0
            ? 'Нет соединения с пирами: раздача не передаёт аудиоданные. '
                  'Повтори попытку, проверь поддержку P2P у VPN или выбери другой источник.'
            : 'Не удалось дождаться аудиоданных. Повтори попытку или выбери другой источник.';
        _failOpening(message);
      }
    } catch (e) {
      if (request == _request) {
        error = e.toString();
        await backend.pause();
      }
    } finally {
      if (request == _request) {
        _statisticsTimer?.cancel();
        connection.cancel();
        _connection = null;
        connectionStatus = null;
        loading = false;
        _publishQueue();
        notifyListeners();
        system?.publish();
      }
    }
  }

  void _failOpening(String message) {
    ++_request;
    _cancelConnection();
    error = message;
    loading = false;
    _openedId = null;
    // A native open/stop can share a lock. UI failure and request invalidation
    // must not wait behind a stalled decoder operation. open(play:false) keeps
    // a late load from starting obsolete audio before this queued stop runs.
    unawaited(backend.stop().catchError((Object _) {}));
    notifyListeners();
    system?.publish();
  }

  void _cancelConnection() {
    _connection?.cancel();
    _connection = null;
    _statisticsTimer?.cancel();
    _statisticsTimer = null;
    _decoderTimer?.cancel();
    _decoderTimer = null;
    connectionStatus = null;
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
      _decoderTimer?.cancel();
      _decoderTimer = null;
      await backend.pause();
    }
    await saveSession();
  }

  Future<void> toggle() => playing || buffering ? pause() : play();
  Future<void> stop() async {
    _restorePosition = position;
    ++_request;
    _cancelConnection();
    loading = false;
    _openedId = null;
    notifyListeners();
    await backend.stop();
    await _session?.setActive(false);
    notifyListeners();
    system?.publish();
    await saveSession();
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
    if (_closed) return;
    if (automatic && repeat == PlayerRepeatMode.one) {
      _restorePosition = null;
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
    if (_closed) return;
    _original.add(track);
    if (next && _cursor >= 0) {
      _order.insert(_cursor + 1, _original.length - 1);
    } else {
      _order.add(_original.length - 1);
    }
    if (_cursor < 0) _cursor = 0;
    if (shuffle) {
      _unshuffledOrder.add(_original.length - 1);
    } else {
      _unshuffledOrder = List.of(_order);
    }
    _publishQueue();
    notifyListeners();
    unawaited(saveSession());
  }

  Future<void> removeQueue(int index) async {
    if (index < 0 || index >= _order.length) return;
    final active = index == _cursor;
    if (active) {
      _restorePosition = null;
      _openedId = null;
    }
    _unshuffledOrder.remove(_order.removeAt(index));
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

  /// Move one occurrence to its final position without reopening the decoder.
  Future<void> moveQueue(int from, int to) async {
    if (_closed ||
        from < 0 ||
        from >= _order.length ||
        to < 0 ||
        to >= _order.length ||
        from == to) {
      return;
    }
    final selected = _cursor >= 0 ? _order[_cursor] : null;
    _order.insert(to, _order.removeAt(from));
    _cursor = selected == null ? -1 : _order.indexOf(selected);
    if (!shuffle) _unshuffledOrder = List.of(_order);
    _publishQueue();
    notifyListeners();
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
      _order = List.of(_unshuffledOrder);
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

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    ++_request;
    _cancelConnection();
    _sleep?.cancel();
    Future<void> cleanup(String stage, FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        // Decoder/source errors can contain private URLs. Log only the stage.
        debugPrint(
          'Mumpa playback shutdown: $stage failed; continuing cleanup.',
        );
      }
    }

    await cleanup('save session', saveSession);
    await cleanup('completion subscription', _completeSubscription.cancel);
    await cleanup('error subscription', _errorSubscription.cancel);
    for (final subscription in _sessionSubscriptions) {
      await cleanup('audio session subscription', subscription.cancel);
    }
    await cleanup('decoder listener', () => backend.removeListener(_onBackend));
    await cleanup('decoder', backend.close);
    await cleanup('controller', dispose);
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
