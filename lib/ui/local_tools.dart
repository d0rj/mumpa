import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../data/library_repository.dart';
import '../data/playlist_files.dart';
import '../domain/local_features.dart';
import '../domain/models.dart';
import '../logic/app_controller.dart';
import '../l10n/app_localizations.dart';
import 'theme.dart';
import 'lan_transfer_view.dart';
import 'components.dart';

Future<void> showLocalTools(BuildContext context, AppController app) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(width: 600, height: 620, child: LocalTools(app: app)),
      ),
    );

class LocalTools extends StatelessWidget {
  const LocalTools({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        tr('Инструменты медиатеки'),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      ListTile(
        leading: const Icon(Icons.auto_awesome),
        title: Text(tr('Умный плейлист')),
        onTap: () => editSmartPlaylist(context, app),
      ),
      ListTile(
        leading: const Icon(Icons.playlist_add),
        title: Text(tr('Импортировать M3U8')),
        onTap: () => importPlaylistFile(app),
      ),
      ListTile(
        leading: const Icon(Icons.ios_share),
        title: Text(tr('Экспортировать медиатеку в M3U8')),
        onTap: () =>
            exportPlaylistFile(app, app.library.mediaTracks, tr('Медиатека')),
      ),
      ListTile(
        leading: const Icon(Icons.bar_chart),
        title: Text(tr('Статистика прослушиваний')),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            child: SizedBox(
              width: 700,
              height: 650,
              child: ListeningStatistics(app: app),
            ),
          ),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.wifi),
        title: Text(tr('Передать по Wi-Fi')),
        onTap: () => showLanTransfer(context, app),
      ),
      ListTile(
        leading: const Icon(Icons.copy_all),
        title: Text(tr('Разобрать известные дубли')),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            child: SizedBox(
              width: 600,
              height: 600,
              child: _DuplicateReview(app: app),
            ),
          ),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.folder_off_outlined),
        title: Text(tr('Найти отсутствующие файлы')),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            child: SizedBox(
              width: 600,
              height: 600,
              child: _MissingFiles(app: app),
            ),
          ),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.restore),
        title: Text(tr('Сбросить ограничения рекомендаций')),
        subtitle: Text(tr('Снова разрешить скрытые треки и исполнителей')),
        onTap: () async {
          await app.library.resetRadioFeedback();
        },
      ),
    ],
  );
}

Future<void> importPlaylistFile(AppController app) async =>
    app.run(tr('Читаем плейлист…'), () async {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['m3u', 'm3u8'],
      );
      if (file == null) return;
      final bytes = <int>[];
      await for (final chunk in file.readAsByteStream()) {
        bytes.addAll(chunk);
        if (bytes.length > PlaylistFiles.maxBytes) {
          throw const FormatException('Файл плейлиста слишком большой.');
        }
      }
      final path = file.path;
      final list = await PlaylistFiles.import(
        app.library,
        utf8.decode(bytes),
        p.basenameWithoutExtension(file.name),
        baseDirectory: path != null && !path.startsWith('content:')
            ? p.dirname(path)
            : null,
        copy: Platform.isAndroid,
      );
      app.openPlaylist(list);
    });

Future<void> exportPlaylistFile(
  AppController app,
  List<Track> tracks,
  String name,
) async => app.run(tr('Сохраняем плейлист…'), () async {
  final paths = <String, String>{};
  for (final track in tracks) {
    final path = await app.library.localPathFor(track);
    if (path != null) paths[track.id] = path;
  }
  if (paths.isEmpty) {
    throw const FormatException('Нет доступных локальных файлов для экспорта.');
  }
  final text = PlaylistFiles.encode(tracks, (t) => paths[t.id]);
  await FilePicker.saveFile(
    fileName: '${name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.m3u8',
    bytes: Uint8List.fromList(utf8.encode(text)),
    mimeType: 'audio/x-mpegurl',
  );
});

Future<void> editSmartPlaylist(
  BuildContext context,
  AppController app, [
  MusicPlaylist? playlist,
]) => showDialog<void>(
  context: context,
  builder: (_) => _SmartEditor(app: app, playlist: playlist),
);

class _SmartEditor extends StatefulWidget {
  const _SmartEditor({required this.app, this.playlist});
  final AppController app;
  final MusicPlaylist? playlist;
  @override
  State<_SmartEditor> createState() => _SmartEditorState();
}

class _SmartEditorState extends State<_SmartEditor> {
  late final rule = Map<String, dynamic>.of(widget.playlist?.smartRule ?? {});
  late final name = TextEditingController(
    text: widget.playlist?.name ?? tr('Новая подборка'),
  );
  late final fields = {
    for (final key in [
      'artist',
      'fromYear',
      'toYear',
      'notPlayedDays',
      'addedDays',
      'limit',
    ])
      key: TextEditingController(text: '${rule[key] ?? ''}'),
  };
  String? error;
  bool saving = false;
  @override
  void dispose() {
    name.dispose();
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('Умный плейлист')),
    content: SizedBox(
      width: 450,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: InputDecoration(labelText: tr('Название')),
            ),
            for (final entry in {
              'liked': 'Только любимое',
              'offline': 'Только офлайн',
              'unplayed': 'Ещё не слушал',
            }.entries)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr(entry.value)),
                value: rule[entry.key] == true,
                onChanged: (v) => setState(() => rule[entry.key] = v),
              ),
            for (final entry in {
              'artist': 'Исполнитель содержит',
              'fromYear': 'Год от',
              'toYear': 'Год до',
              'notPlayedDays': 'Не слушал дней',
              'addedDays': 'Добавлены за последние дни',
              'limit': 'Максимум треков (до 5000)',
            }.entries)
              TextField(
                controller: fields[entry.key],
                keyboardType: entry.key == 'artist'
                    ? TextInputType.text
                    : TextInputType.number,
                decoration: InputDecoration(labelText: tr(entry.value)),
              ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: rule['sort'] as String? ?? 'title',
              decoration: InputDecoration(labelText: tr('Сортировка')),
              items: [
                DropdownMenuItem(
                  value: 'title',
                  child: Text(tr('По названию')),
                ),
                DropdownMenuItem(
                  value: 'rare',
                  child: Text(tr('Редко слушаемые сначала')),
                ),
                DropdownMenuItem(
                  value: 'recent',
                  child: Text(tr('Недавно добавленные сначала')),
                ),
              ],
              onChanged: (v) => rule['sort'] = v,
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.orangeAccent)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('Отмена')),
      ),
      FilledButton(
        onPressed: saving
            ? null
            : () async {
                final updated = Map<String, dynamic>.of(rule)
                  ..['artist'] = fields['artist']!.text.trim();
                for (final key in fields.keys.where((k) => k != 'artist')) {
                  final text = fields[key]!.text.trim();
                  final value = int.tryParse(text);
                  if (text.isNotEmpty &&
                      (value == null ||
                          value < 0 ||
                          value > (key == 'limit' ? 5000 : 9999))) {
                    setState(() => error = tr('Проверь числовые условия.'));
                    return;
                  }
                  if (value == null) {
                    updated.remove(key);
                  } else {
                    updated[key] = value;
                  }
                }
                if (name.text.trim().isEmpty ||
                    updated['fromYear'] != null &&
                        updated['toYear'] != null &&
                        (updated['fromYear'] as int) >
                            (updated['toYear'] as int)) {
                  setState(
                    () => error = tr('Проверь название и диапазон лет.'),
                  );
                  return;
                }
                setState(() => saving = true);
                try {
                  final result = await widget.app.library.saveSmartPlaylist(
                    name.text,
                    updated,
                    id: widget.playlist?.id,
                  );
                  widget.app.openPlaylist(result);
                  if (context.mounted) Navigator.pop(context);
                } catch (_) {
                  if (mounted) {
                    setState(() {
                      saving = false;
                      error = tr('Не удалось сохранить плейлист.');
                    });
                  }
                }
              },
        child: Text(tr('Сохранить')),
      ),
    ],
  );
}

class ListeningStatistics extends StatefulWidget {
  const ListeningStatistics({super.key, required this.app});
  final AppController app;
  @override
  State<ListeningStatistics> createState() => _ListeningStatisticsState();
}

class _ListeningStatisticsState extends State<ListeningStatistics> {
  String period = '30';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app.library,
    builder: (_, _) {
      final now = DateTime.now();
      final year = int.tryParse(period.replaceFirst('year:', '')) ?? now.year;
      final since = period.startsWith('year:')
          ? DateTime(year)
          : DateTime(
              now.year,
              now.month,
              now.day,
            ).subtract(Duration(days: int.parse(period) - 1));
      final until = period.startsWith('year:') ? DateTime(year, 12, 31) : now;
      final stats = widget.app.library.listeningSummary(
        since: since,
        until: until,
      );
      final artists = stats.artists.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final years = {
        now.year,
        ...widget.app.library.features.listening.values.map(
          (b) => int.parse(b.day.substring(0, 4)),
        ),
      }.toList()..sort((a, b) => b.compareTo(a));
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            tr('Статистика прослушиваний'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: period,
            items: [
              DropdownMenuItem(value: '7', child: Text(tr('Последние 7 дней'))),
              DropdownMenuItem(
                value: '30',
                child: Text(tr('Последние 30 дней')),
              ),
              for (final y in years)
                DropdownMenuItem(
                  value: 'year:$y',
                  child: Text(tr('Итоги {0} года', [y])),
                ),
            ],
            onChanged: (v) => setState(() => period = v!),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              tr('{0} минут · {1} прослушиваний', [
                stats.milliseconds ~/ 60000,
                stats.plays,
              ]),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Text(tr('Календарь прослушиваний')),
          const SizedBox(height: 12),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (
                var day = since;
                !day.isAfter(until);
                day = DateTime(day.year, day.month, day.day + 1)
              )
                Tooltip(
                  message:
                      '${LocalFeatures.dayKey(day)} · ${(stats.daily[LocalFeatures.dayKey(day)] ?? 0) ~/ 60000} ${tr('мин')}',
                  child: Semantics(
                    label:
                        '${LocalFeatures.dayKey(day)}: ${(stats.daily[LocalFeatures.dayKey(day)] ?? 0) ~/ 60000} ${tr('мин')}',
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        color: Color.lerp(
                          const Color(0xFF29332B),
                          accent,
                          ((stats.daily[LocalFeatures.dayKey(day)] ?? 0) /
                                  3600000)
                              .clamp(0.0, 1.0),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(tr('Любимые исполнители')),
          for (final artist in artists.take(20))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(artist.key),
              trailing: Text('${artist.value ~/ 60000} ${tr('мин')}'),
            ),
          Text(
            tr(
              'Подробные данные собираются с момента обновления. Прошлые периоды не восстанавливаются из общих счётчиков.',
            ),
            style: const TextStyle(color: muted),
          ),
        ],
      );
    },
  );
}

Future<void> editTrackMetadata(
  BuildContext context,
  AppController app,
  Track track,
) => showDialog<void>(
  context: context,
  builder: (_) => _MetadataEditor(app: app, track: track),
);

class _MetadataEditor extends StatefulWidget {
  const _MetadataEditor({required this.app, required this.track});
  final AppController app;
  final Track track;
  @override
  State<_MetadataEditor> createState() => _MetadataEditorState();
}

class _MetadataEditorState extends State<_MetadataEditor> {
  late final fields = {
    for (final e in {
      'title': widget.track.title,
      'artist': widget.track.artist,
      'albumArtist': widget.track.albumArtist ?? widget.track.artist,
      'album': widget.track.album,
      'year': '${widget.track.year ?? ''}',
    }.entries)
      e.key: TextEditingController(text: e.value),
  };
  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('Изменить метаданные')),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in {
              'title': 'Название',
              'artist': 'Исполнитель',
              'albumArtist': 'Исполнитель альбома',
              'album': 'Альбом',
              'year': 'Год',
            }.entries)
              TextField(
                controller: fields[entry.key],
                decoration: InputDecoration(labelText: tr(entry.value)),
              ),
            Text(
              tr(
                'Правки сохраняются в Mumpa. Исходные аудиофайлы не изменяются.',
              ),
              style: const TextStyle(color: muted),
            ),
            TextButton(
              onPressed: () async {
                await relinkTrackFile(widget.app, widget.track);
              },
              child: Text(tr('Выбрать новое расположение файла')),
            ),
            TextButton(
              onPressed: () async {
                await widget.app.run(tr('Сохраняем обложку…'), () async {
                  final image = await FilePicker.pickFile(
                    type: FileType.custom,
                    allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
                  );
                  if (image == null) return;
                  final bytes = <int>[];
                  await for (final chunk in image.readAsByteStream()) {
                    bytes.addAll(chunk);
                    if (bytes.length > 16 * 1024 * 1024) {
                      throw const FormatException('Обложка больше 16 МБ.');
                    }
                  }
                  final target = File(
                    p.join(
                      widget.app.library.root.path,
                      'artwork',
                      '${stableId(base64Encode(bytes))}${p.extension(image.name)}',
                    ),
                  );
                  await target.parent.create(recursive: true);
                  await target.writeAsBytes(bytes, flush: true);
                  await widget.app.library.editMetadata(
                    widget.app.library.byId(widget.track.id) ?? widget.track,
                    {'artPath': target.path},
                  );
                });
              },
              child: Text(tr('Выбрать обложку')),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('Отмена')),
      ),
      FilledButton(
        onPressed: () async {
          await widget.app.run(tr('Сохраняем метаданные…'), () async {
            await widget.app.library.editMetadata(
              widget.app.library.byId(widget.track.id) ?? widget.track,
              {
                for (final e in fields.entries.where((e) => e.key != 'year'))
                  e.key: e.value.text,
                'year': int.tryParse(fields['year']!.text),
              },
            );
          });
          if (context.mounted && widget.app.error == null) {
            Navigator.pop(context);
          }
        },
        child: Text(tr('Сохранить')),
      ),
    ],
  );
}

Future<void> relinkTrackFile(
  AppController app,
  Track track,
) async => app.run(tr('Проверяем файл…'), () async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: audioExtensions.toList(),
  );
  if (file == null) return;
  if (!Platform.isAndroid &&
      file.path != null &&
      !file.path!.startsWith('content:')) {
    await app.library.relinkTrack(track.id, file.path!);
    return;
  }
  final stage = File(
    p.join(
      app.library.root.path,
      'imports',
      'relink-${DateTime.now().microsecondsSinceEpoch}${p.extension(file.name)}',
    ),
  );
  await stage.parent.create(recursive: true);
  try {
    final sink = stage.openWrite();
    var received = 0;
    try {
      await for (final chunk in file.readAsByteStream()) {
        received += chunk.length;
        if (received >
            (track.bytes > 0 ? track.bytes : 2 * 1024 * 1024 * 1024)) {
          throw const FormatException('Размер файла не совпал.');
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    await app.library.relinkTrack(track.id, stage.path, copy: true);
  } finally {
    if (await stage.exists()) await stage.delete();
  }
});

class _DuplicateReview extends StatelessWidget {
  const _DuplicateReview({required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app.library,
    builder: (_, _) {
      final rows = app.library
          .matchedTracks(app.library.mediaTracks)
          .where((r) => r.group.multiple)
          .toList();
      return ListView(
        children: [
          ListTile(
            title: Text(tr('Известные дубли')),
            subtitle: Text(
              tr(
                'Выбери основную версию или отметь ошибочное совпадение. Файлы сохраняются.',
              ),
            ),
          ),
          for (final row in rows)
            ListTile(
              title: Text(row.preferred.title),
              subtitle: Text(
                '${row.preferred.artist} · ${row.group.variants.length}',
              ),
              onTap: () => showKnownTrackVersions(context, app, row),
            ),
        ],
      );
    },
  );
}

class _MissingFiles extends StatefulWidget {
  const _MissingFiles({required this.app});
  final AppController app;
  @override
  State<_MissingFiles> createState() => _MissingFilesState();
}

class _MissingFilesState extends State<_MissingFiles> {
  late Future<List<Track>> missing = _scan();
  Future<List<Track>> _scan() async {
    final result = <Track>[];
    for (final track in widget.app.library.mediaTracks.where(
      (t) => t.source == TrackSource.local,
    )) {
      if (await widget.app.library.localPathFor(track) == null) {
        result.add(track);
      }
    }
    return result;
  }

  Future<void> _findInFolder() async {
    final directory = await FilePicker.getDirectoryPath();
    if (directory == null) return;
    final tracks = await missing;
    final candidates = await widget.app.run(
      tr('Ищем перемещённые файлы…'),
      () =>
          widget.app.library.findRelinkCandidates(Directory(directory), tracks),
    );
    if (!mounted || candidates == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Найдено совпадений: {0}', [candidates.length])),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(
            child: Text(
              candidates.entries
                  .map(
                    (entry) =>
                        '${widget.app.library.byId(entry.key)?.title}\n${entry.value}',
                  )
                  .join('\n\n'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Отмена')),
          ),
          FilledButton(
            onPressed: candidates.isEmpty
                ? null
                : () => Navigator.pop(context, true),
            child: Text(tr('Восстановить пути')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.app.run(tr('Восстанавливаем пути…'), () async {
        for (final entry in candidates.entries) {
          await widget.app.library.relinkTrack(entry.key, entry.value);
        }
      });
    }
    if (mounted) setState(() => missing = _scan());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Track>>(
    future: missing,
    builder: (_, snapshot) => !snapshot.hasData
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            children: [
              ListTile(
                title: Text(tr('Отсутствующие файлы')),
                subtitle: Text(
                  tr(
                    'Выбор нового расположения сохраняет избранное и плейлисты.',
                  ),
                ),
              ),
              if (!Platform.isAndroid)
                TextButton.icon(
                  onPressed: _findInFolder,
                  icon: const Icon(Icons.folder_open),
                  label: Text(tr('Искать в папке')),
                ),
              for (final track in snapshot.data!)
                ListTile(
                  title: Text(track.title),
                  subtitle: Text(track.artist),
                  trailing: const Icon(Icons.folder_open),
                  onTap: () async {
                    await relinkTrackFile(widget.app, track);
                    if (mounted) setState(() => missing = _scan());
                  },
                ),
            ],
          ),
  );
}
