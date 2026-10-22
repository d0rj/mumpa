import '../l10n/app_localizations.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../domain/audio_preferences.dart';
import '../logic/app_controller.dart';
import 'theme.dart';
import 'accessible_slider.dart';

class AudioSettings extends StatelessWidget {
  const AudioSettings({super.key, required this.app});
  final AppController app;
  void _set(String key, Object value) => unawaited(
    app.playback.setAudioSetting(key, value).catchError((Object _) {
      app.reportError(
        tr("Не удалось применить настройки звука. Попробуй ещё раз."),
      );
    }),
  );

  @override
  Widget build(BuildContext context) {
    final prefs = app.playback.audioPreferences;
    final crossfade = app.library.settings['crossfadeEnabled'] == true;
    final seconds = prefs.crossfadeSeconds > 0 ? prefs.crossfadeSeconds : 5.0;
    final labels = {
      'flat': tr("Ровный"),
      'bass': tr("Больше баса"),
      'treble': tr("Высокие частоты"),
      'vocal': tr("Вокал"),
      'rock': tr("Рок"),
      'electronic': tr("Электроника"),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('equalizer-enabled'),
          contentPadding: EdgeInsets.zero,
          title: Text(tr("Эквалайзер")),
          subtitle: Text(tr("Настрой баланс низких, средних и высоких частот")),
          value: prefs.equalizerEnabled,
          onChanged: (v) => _set('equalizerEnabled', v),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('equalizer-preset-${prefs.preset}'),
          initialValue: prefs.preset ?? 'custom',
          isExpanded: true,
          decoration: InputDecoration(labelText: tr("Пресет")),
          items: [
            for (final e in labels.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
            DropdownMenuItem(value: 'custom', child: Text(tr("Свой"))),
          ],
          onChanged: prefs.equalizerEnabled
              ? (v) {
                  if (v != null && AudioPreferences.presets.containsKey(v)) {
                    _set('equalizerGains', AudioPreferences.presets[v]!);
                  }
                }
              : null,
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 205,
          child: Row(
            children: [
              for (var i = 0; i < 6; i++)
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '${prefs.gains[i] > 0 ? '+' : ''}${prefs.gains[i].round()}',
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: AccessibleSlider(
                            child: Slider(
                              key: ValueKey('equalizer-band-$i'),
                              min: -12,
                              max: 12,
                              divisions: 24,
                              value: prefs.gains[i],
                              label: '${prefs.gains[i].round()} dB',
                              onChanged: prefs.equalizerEnabled
                                  ? (v) {
                                      final gains = prefs.gains.toList();
                                      gains[i] = v;
                                      _set('equalizerGains', gains);
                                    }
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      Text(
                        ['60', '150', '400', '1k', '2.4k', '15k'][i],
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          tr("±12 дБ · Настройки полос сохраняются при отключении."),
          style: TextStyle(color: muted, fontSize: 11),
        ),
        TextButton(
          onPressed: () =>
              _set('equalizerGains', AudioPreferences.presets['flat']!),
          child: Text(tr("Сбросить эквалайзер")),
        ),
        const Divider(height: 32),
        SwitchListTile.adaptive(
          key: const ValueKey('crossfade-enabled'),
          contentPadding: EdgeInsets.zero,
          title: Text(tr("Плавные переходы")),
          subtitle: Text(tr("Конец трека затихает, пока начинается следующий")),
          value: crossfade,
          onChanged: (v) => _set('crossfadeEnabled', v),
        ),
        if (crossfade) ...[
          Text(tr("Длительность перехода: {0} с", [seconds.round()])),
          AccessibleSlider(
            child: Slider(
              key: const ValueKey('crossfade-duration'),
              min: 1,
              max: 12,
              divisions: 11,
              value: seconds,
              label: tr("{0} с", [seconds.round()]),
              onChanged: (v) => _set('crossfadeSeconds', v),
            ),
          ),
        ],
        Text(
          tr(
            "При автоматическом переходе к следующему готовому треку. Если файл ещё загружается, играет обычный переход. Повтор одного трека сохраняется.",
          ),
          style: TextStyle(color: muted, fontSize: 11),
        ),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          key: const ValueKey('normalize-volume'),
          contentPadding: EdgeInsets.zero,
          title: Text(tr("Одинаковая громкость треков")),
          subtitle: Text(
            tr("Выравнивать воспринимаемую громкость во время воспроизведения"),
          ),
          value: prefs.normalize,
          onChanged: (v) => _set('normalizeVolume', v),
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('mono-audio'),
          contentPadding: EdgeInsets.zero,
          title: Text(tr("Монозвук")),
          subtitle: Text(
            tr("Смешивать левый и правый каналы в обоих наушниках"),
          ),
          value: prefs.mono,
          onChanged: (v) => _set('monoAudio', v),
        ),
      ],
    );
  }
}
