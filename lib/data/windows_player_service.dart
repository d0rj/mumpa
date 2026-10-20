import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../logic/playback_controller.dart';

/// Connects the Windows shell controls to the same queue as the app UI.
/// The owner must await application cleanup in [onQuit]; native destruction
/// happens only after that callback finishes successfully.
class WindowsPlayerService {
  WindowsPlayerService({
    required this.playback,
    required this.onQuit,
    MethodChannel? channel,
    bool? enabled,
  }) : _channel = channel ?? const MethodChannel('app.mumpa/windows_player'),
       _enabled = enabled ?? Platform.isWindows;

  final PlaybackController playback;
  final Future<void> Function() onQuit;
  final MethodChannel _channel;
  final bool _enabled;
  bool _initialized = false, _disposed = false, _quitting = false;
  bool _publishing = false;
  Map<String, bool> capabilities = const {};
  Map<String, Object>? _pendingState, _lastState;
  Future<void>? _quit;
  Future<void>? _closing;

  bool get available => _initialized && !_disposed;

  Future<void> initialize() async {
    if (!_enabled || _initialized || _disposed) return;
    _channel.setMethodCallHandler(_handleMethod);
    try {
      final result = await _channel.invokeMapMethod<String, bool>('initialize');
      if (_disposed) return;
      capabilities = Map.unmodifiable(result ?? const {});
      _initialized = true;
      playback.addListener(_publish);
      playback.library.addListener(_publish);
      _publish();
    } on MissingPluginException {
      _channel.setMethodCallHandler(null);
    }
  }

  Future<void> _handleMethod(MethodCall call) async {
    if (call.method != 'command' || call.arguments is! String) return;
    if (_disposed || !_initialized) return;
    final command = call.arguments as String;
    if (command == 'quit') {
      await requestQuit();
      return;
    }
    if (_quitting || playback.current == null) return;
    switch (command) {
      case 'play':
        await playback.play();
      case 'pause':
        await playback.pause();
      case 'stop':
        await playback.stop();
      case 'toggle':
        await playback.toggle();
      case 'next':
        await playback.next();
      case 'previous':
        await playback.previous();
    }
  }

  void _publish() {
    if (!available || _quitting) return;
    final track = playback.current;
    final state = <String, Object>{
      'english': playback.library.settings['language'] == 'en',
      'hasTrack': track != null,
      'title': track?.title ?? '',
      'artist': track?.artist ?? '',
      'album': track?.album ?? '',
      // Pause also cancels a pending torrent/decoder startup in the app.
      'playing': playback.playing || playback.buffering,
      'canPrevious': track != null,
      'canNext':
          track != null &&
          (playback.index + 1 < playback.queue.length ||
              playback.repeat == PlayerRepeatMode.all),
    };
    // Decoder position updates are frequent; publish only shell-visible changes.
    if (mapEquals(state, _lastState)) return;
    _lastState = state;
    _pendingState = state;
    if (!_publishing) unawaited(_flushState());
  }

  Future<void> _flushState() async {
    _publishing = true;
    try {
      while (_pendingState != null && available && !_quitting) {
        final state = _pendingState!;
        _pendingState = null;
        try {
          await _channel.invokeMethod<void>('updateState', state);
        } on PlatformException {
          // Shell availability must not stop audio playback.
          _lastState = null;
        } on MissingPluginException {
          _lastState = null;
          break;
        }
      }
    } finally {
      _publishing = false;
    }
  }

  Future<void> show() async {
    if (available) await _channel.invokeMethod<void>('show');
  }

  Future<Map<String, dynamic>> diagnostics() async {
    if (!_enabled || _disposed) return const {};
    return await _channel.invokeMapMethod<String, dynamic>('diagnostics') ??
        const {};
  }

  Future<void> requestQuit() => _quit ??= _finishQuit();

  Future<void> _finishQuit() async {
    if (_disposed || _quitting) return;
    _quitting = true;
    if (_initialized) playback.removeListener(_publish);
    if (_initialized) playback.library.removeListener(_publish);
    _pendingState = null;
    try {
      await onQuit();
      if (_initialized && !_disposed) {
        await _channel.invokeMethod<void>('quitReady');
      }
    } catch (_) {
      _quitting = false;
      _quit = null;
      if (_initialized && !_disposed) {
        playback.addListener(_publish);
        playback.library.addListener(_publish);
        await _channel.invokeMethod<void>('quitFailed');
        _lastState = null;
        _publish();
      }
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_disposed) return;
    if (_initialized && !_quitting) playback.removeListener(_publish);
    if (_initialized && !_quitting) playback.library.removeListener(_publish);
    _disposed = true;
    _pendingState = null;
    _channel.setMethodCallHandler(null);
    if (_initialized) {
      try {
        await _channel.invokeMethod<void>('dispose');
      } on MissingPluginException {
        // A test or an engine teardown may already have removed the channel.
      } on PlatformException {
        // Native window destruction also releases these resources.
      }
    }
  }

  void dispose() => unawaited(close());
}
