import 'dart:math' as math;

/// Persisted independently of the queue and the user's volume control.
class AudioPreferences {
  AudioPreferences({
    this.equalizerEnabled = false,
    List<double> gains = const [0, 0, 0, 0, 0, 0],
    this.normalize = false,
    this.mono = false,
    this.crossfadeSeconds = 0,
  }) : gains = List.unmodifiable(gains);

  static const frequencies = [60, 150, 400, 1000, 2400, 15000];
  static const presets = <String, List<double>>{
    'flat': [0, 0, 0, 0, 0, 0],
    'bass': [6, 4, 1, 0, -1, -2],
    'treble': [-2, -1, 0, 1, 4, 6],
    'vocal': [-3, -2, 1, 4, 3, 0],
    'rock': [4, 2, -2, -1, 2, 4],
    'electronic': [5, 3, 0, -2, 2, 4],
  };
  final bool equalizerEnabled, normalize, mono;
  final List<double> gains;
  final double crossfadeSeconds;

  factory AudioPreferences.fromSettings(Map<String, dynamic> settings) {
    final raw = settings['equalizerGains'];
    double finite(Object? value, double fallback, double min, double max) =>
        value is num && value.isFinite
        ? value.toDouble().clamp(min, max)
        : fallback;
    return AudioPreferences(
      equalizerEnabled: settings['equalizerEnabled'] == true,
      gains: List.generate(
        6,
        (i) =>
            finite(raw is List && i < raw.length ? raw[i] : null, 0, -12, 12),
      ),
      normalize: settings['normalizeVolume'] == true,
      mono: settings['monoAudio'] == true,
      crossfadeSeconds: settings['crossfadeEnabled'] == true
          ? finite(settings['crossfadeSeconds'], 5, 1, 12)
          : 0,
    );
  }

  String? get preset => presets.entries
      .where(
        (p) => List.generate(6, (i) => p.value[i] == gains[i]).every((v) => v),
      )
      .firstOrNull
      ?.key;

  /// Reserve EQ headroom before the bands, without changing user volume.
  double get outputGain => equalizerEnabled
      ? math.pow(10, -gains.fold<double>(0, math.max) / 20).toDouble()
      : 1;

  /// libmpv's lavfi graph. A pan matrix supplies preamp gain in this runtime.
  /// Normalization runs before EQ so the selected tonal balance is preserved.
  String get filterGraph {
    final filters = <String>[];
    if (normalize) filters.add('loudnorm=I=-16:TP=-1.5:LRA=11');
    if (equalizerEnabled) {
      // Integer input must not clip inside EQ before native volume applies
      // the headroom gain. Keep the filter chain in floating point.
      if (gains.any((gain) => gain != 0)) {
        filters.add('aformat=sample_fmts=fltp:channel_layouts=stereo');
        if (outputGain < 1) {
          final gain = outputGain.toStringAsFixed(8);
          filters.add('pan=args=stereo|c0=$gain*c0|c1=$gain*c1');
        }
      }
      for (var i = 0; i < 6; i++) {
        if (gains[i] != 0) {
          filters.add(
            'equalizer=f=${frequencies[i]}:t=o:w=2:g=${gains[i].toStringAsFixed(1)}',
          );
        }
      }
      if (gains.any((gain) => gain != 0)) {
        filters.add('alimiter=limit=0.95:level=false');
      }
    }
    // aformat handles mono/multichannel inputs; average L/R into both ears.
    if (mono) {
      filters.add(
        'aformat=channel_layouts=stereo,pan=args=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1',
      );
    }
    return filters.isEmpty ? '' : 'lavfi=[${filters.join(',')}]';
  }
}
