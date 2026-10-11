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
