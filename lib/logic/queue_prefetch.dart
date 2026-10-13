import 'dart:async';

import '../data/download_repository.dart';
import '../data/library_repository.dart';
import '../domain/models.dart';
import 'playback_controller.dart';

/// A bounded window refreshed by transport/queue changes, not download progress.
/// Finishing a file never drains the rest of a paused-in-place playlist.
class QueuePrefetch {
  QueuePrefetch({
    required this.library,
    required this.playback,
    required this.downloads,
  }) {
    _lastCount = count;
    playback.controlsState.addListener(_refresh);
    library.addListener(_onLibrary);
    _refresh();
  }

  final LibraryRepository library;
  final PlaybackController playback;
  final DownloadRepository downloads;
  late int _lastCount;
  int _generation = 0;
  Object? _signature;
  bool _closed = false;

  int get count {
    final value = library.settings['prefetchTracks'];
    return value is num && value.toInt() >= 0 && value.toInt() <= 10
        ? value.toInt()
        : 3;
  }

  Future<void> setCount(int value) async {
    RangeError.checkValueInInterval(value, 0, 10, 'prefetchTracks');
    await library.setSetting('prefetchTracks', value);
  }

  void _onLibrary() {
    if (_closed || _lastCount == count) return;
    _lastCount = count;
    _refresh();
  }

  void _refresh() {
    if (_closed) return;
    final active = count > 0 && (playback.playing || playback.loading);
    final signature = active
        ? (playback.current?.id, playback.index, playback.queueRevision, count)
        : null;
    if (_signature == signature) return;
    _signature = signature;
    final generation = ++_generation;
    if (!active) {
      downloads.setPrefetchTracks(const []);
      return;
    }
    final upcoming = playback.queue.skip(playback.index + 1).toList();
    final limit = count;
    unawaited(_select(upcoming, limit, generation));
  }

  Future<void> _select(List<Track> upcoming, int limit, int generation) async {
    final selected = <Track>[];
    final seen = <Object>{};
    for (final original in upcoming) {
      if (_closed || generation != _generation) return;
      final track = library.byId(original.id) ?? original;
      if (track.source != TrackSource.torrent) continue;
      final Object key = track.torrentHash != null && track.torrentPath != null
          ? (
              track.torrentHash!.toLowerCase(),
              track.torrentPath!.replaceAll('\\', '/'),
            )
          : track.id;
      if (!seen.add(key)) continue;
      if (await library.localPathFor(track) != null) continue;
      selected.add(track);
      if (selected.length == limit) break;
    }
    if (!_closed && generation == _generation) {
      downloads.setPrefetchTracks(selected);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    ++_generation;
    playback.controlsState.removeListener(_refresh);
    library.removeListener(_onLibrary);
    downloads.setPrefetchTracks(const []);
  }
}
