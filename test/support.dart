import 'dart:async';
import 'package:mumpa/logic/playback_controller.dart';

class FakeAudioBackend extends AudioBackend {
  String? opened;
  bool _playing = false;
  Duration _position = Duration.zero;
  double _volume = .8;
  final completion = StreamController<void>.broadcast();
  final failure = StreamController<String>.broadcast();
  @override
  bool get playing => _playing;
  @override
  bool get buffering => false;
  @override
  Duration get position => _position;
  @override
  Duration get duration => const Duration(seconds: 24);
  @override
  double get volume => _volume;
  @override
  Stream<void> get completed => completion.stream;
  @override
  Stream<String> get errors => failure.stream;
  @override
  Future<void> open(
    String uri, {
    bool play = true,
    Duration start = Duration.zero,
  }) async {
    opened = uri;
    _playing = play;
    _position = start;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _position = Duration.zero;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    notifyListeners();
  }

  @override
  Future<void> setVolume(double value) async {
    _volume = value;
    notifyListeners();
  }

  @override
  Future<void> close() async {
    await completion.close();
    await failure.close();
    dispose();
  }
}
