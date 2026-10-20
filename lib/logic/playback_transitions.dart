part of 'playback_controller.dart';

/// Prepares only the immediate successor. Preparation never changes the queue.
class _PlaybackTransitions {
  _PlaybackTransitions(this.controller);
  final PlaybackController controller;
  SourceOperation? _operation;
  Object? _candidate, _attempted;
  String? _readyUri;
  bool _starting = false;

  int? get _successor {
    final c = controller;
    if (c.repeat == PlayerRepeatMode.one || c._order.length < 2) return null;
    if (c.index + 1 < c._order.length) return c.index + 1;
    return c.repeat == PlayerRepeatMode.all ? 0 : null;
  }

  Object? get _signature {
    final c = controller;
    if (c.index < 0 || c.current == null) return null;
    final next = _successor;
    return next == null
        ? null
        : (
            c._request,
            c._order[c.index],
            c._order[next],
            c.audioPreferences.crossfadeSeconds,
          );
  }

  Future<void> cancel() async {
    _operation?.cancel();
    _operation = null;
    _candidate = _attempted = _readyUri = null;
    await controller.backend.cancelPrepared();
  }

  void tick() {
    final c = controller;
    final seconds = c.audioPreferences.crossfadeSeconds;
    if (c._closed ||
        !c.backend.supportsCrossfade ||
        c.backend.transitioning ||
        seconds <= 0 ||
        !c.playing ||
        !c._wantsPlayback ||
        c.loading ||
        c.buffering ||
        c.duration <= Duration.zero ||
        _starting) {
      return;
    }
    final remaining = c.duration - c.position;
    if (remaining <= Duration.zero ||
        c.duration.inMilliseconds < seconds * 2000) {
      return;
    }
    final signature = _signature;
    if (signature == null) return;
    if (_candidate != signature &&
        _attempted != signature &&
        remaining.inMilliseconds <= (seconds + 15) * 1000) {
      _attempted = signature;
      unawaited(_prepare(signature));
    }
    if (_candidate == signature &&
        _readyUri != null &&
        remaining.inMilliseconds <= seconds * 1000) {
      _starting = true;
      unawaited(_start(signature, remaining));
    }
  }

  Future<void> _prepare(Object signature) async {
    _operation?.cancel();
    final operation = _operation = SourceOperation();
    try {
      final c = controller;
      final track = c.queue[_successor!];
      final uri = await operation
          .wait(c.resolve(track, operation: operation))
          .timeout(const Duration(seconds: 10));
      if (operation.cancelled || signature != _signature) return;
      if (track.source == TrackSource.torrent &&
          Uri.parse(uri).scheme.startsWith('http')) {
        await c.torrents.waitForAudio(
          Uri.parse(uri),
          operation: operation,
          timeout: const Duration(seconds: 8),
        );
      }
      if (operation.cancelled || signature != _signature) return;
      if (await c.backend.prepareNext(uri) &&
          !operation.cancelled &&
          signature == _signature) {
        _candidate = signature;
        _readyUri = uri;
        tick();
      }
    } catch (_) {
      // Leave normal completion/skip handling in charge of failed sources.
    }
  }

  Future<void> _start(Object signature, Duration remaining) async {
    try {
      final c = controller;
      await c.backend.crossfade(remaining, () {
        if (signature != _signature ||
            !c._wantsPlayback ||
            c._closed ||
            c.loading) {
          return false;
        }
        final next = _successor;
        if (next == null) return false;
        c._cursor = next;
        ++c._request;
        c._openedId = c.current!.id;
        c._initialPlaybackPosition = Duration.zero;
        c._restorePosition = null;
        c._countedListenRequest = null;
        c._failedEntries.clear();
        c._publishQueue();
        c.notifyListeners();
        unawaited(c.library.markPlayed(c.current!.id));
        unawaited(c.saveSession());
        _candidate = _readyUri = null;
        return true;
      });
    } finally {
      _starting = false;
    }
  }
}
