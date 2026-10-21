import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../data/lyrics_repository.dart';
import '../data/library_repository.dart';
import '../domain/lyrics.dart';
import '../l10n/app_localizations.dart';
import '../logic/app_controller.dart';
import 'theme.dart';

class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.app});
  final AppController app;
  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  late final repository = LyricsRepository(widget.app.library.root);
  final scroll = ScrollController();
  Lyrics? lyrics;
  String? id, error;
  String? _embedded;
  int revision = 0, lastIndex = -2;
  bool loading = false, follow = true;
  @override
  void initState() {
    super.initState();
    widget.app.playback.controlsState.addListener(_changed);
    widget.app.library.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    ++revision;
    widget.app.playback.controlsState.removeListener(_changed);
    widget.app.library.removeListener(_changed);
    repository.close();
    scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (id != widget.app.playback.current?.id ||
        _embedded != widget.app.playback.current?.lyrics) {
      id = widget.app.playback.current?.id;
      _embedded = widget.app.playback.current?.lyrics;
      lyrics = Lyrics.parse(_embedded ?? '');
      lastIndex = -2;
      _load();
    }
  }

  Future<void> _load({bool remote = false}) async {
    final track = widget.app.playback.current;
    if (track == null) return;
    final current = ++revision;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await repository.load(
        track,
        remote: remote || widget.app.library.settings['lyricsLookup'] == true,
        force: remote,
      );
      if (mounted && current == revision) setState(() => lyrics = result);
    } catch (e) {
      if (mounted && current == revision) {
        setState(
          () => error = e is HttpException
              ? e.message
              : tr('Не удалось получить текст песни.'),
        );
      }
    } finally {
      if (mounted && current == revision) setState(() => loading = false);
    }
  }

  Future<void> _import() async {
    final track = widget.app.playback.current;
    if (track == null) return;
    final picked = await FilePicker.pickFile(
      allowedExtensions: ['lrc', 'txt'],
      type: FileType.custom,
    );
    if (picked == null) return;
    try {
      final bytes = <int>[];
      await for (final chunk in picked.readAsByteStream()) {
        bytes.addAll(chunk);
        if (bytes.length > LyricsRepository.maxBytes) {
          throw const FormatException('Текст песни слишком большой.');
        }
      }
      final text = utf8.decode(bytes);
      await repository.save(track, text, user: true);
      if (mounted && widget.app.playback.current?.id == track.id) await _load();
    } catch (_) {
      if (mounted) {
        setState(() => error = tr('Не удалось прочитать текст песни.'));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: loading ? null : () => _load(remote: true),
            icon: const Icon(Icons.search),
            label: Text(tr('Найти текст')),
          ),
          TextButton.icon(
            onPressed: _import,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(tr('Открыть LRC')),
          ),
          if (lyrics?.synced == true) ...[
            IconButton(
              tooltip: tr('Текст раньше на 0,25 с'),
              onPressed: () => _offset(-250),
              icon: const Icon(Icons.remove),
            ),
            Text(
              tr('{0} с', [
                ((widget.app.library.features.lyricOffsets[id] ?? 0) / 1000)
                    .toStringAsFixed(2),
              ]),
            ),
            IconButton(
              tooltip: tr('Текст позже на 0,25 с'),
              onPressed: () => _offset(250),
              icon: const Icon(Icons.add),
            ),
            IconButton(
              tooltip: tr('Следить за текстом'),
              onPressed: () => setState(() => follow = !follow),
              color: follow ? accent : muted,
              icon: const Icon(Icons.vertical_align_center),
            ),
          ],
        ],
      ),
      if (loading)
        Text(tr('Читаем текст…'), style: const TextStyle(color: muted)),
      if (error != null)
        Padding(padding: const EdgeInsets.all(8), child: Text(error!)),
      Expanded(
        child: lyrics?.synced == true
            ? ListenableBuilder(
                listenable: widget.app.playback,
                builder: (context, _) {
                  final offset =
                      widget.app.library.features.lyricOffsets[id] ?? 0;
                  final index = lyrics!.indexAt(
                    widget.app.playback.position -
                        Duration(milliseconds: offset),
                  );
                  if (index != lastIndex && follow) {
                    lastIndex = index;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && scroll.hasClients && index >= 0) {
                        scroll.animateTo(
                          (index * 84.0 -
                                  scroll.position.viewportDimension / 2 +
                                  42)
                              .clamp(0, scroll.position.maxScrollExtent),
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        );
                      }
                    });
                  }
                  return ListView.builder(
                    controller: scroll,
                    itemExtent: 84,
                    itemCount: lyrics!.lines.length,
                    itemBuilder: (_, i) => InkWell(
                      key: ValueKey('lyric-line-$i'),
                      onTap: () => widget.app.playback.seek(
                        lyrics!.lines[i].time + Duration(milliseconds: offset),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 10,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            lyrics!.lines[i].text,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: i == index
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: i == index ? accent : muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: SelectableText(
                  lyrics?.plain.isNotEmpty == true
                      ? lyrics!.plain
                      : tr('Текста пока нет'),
                  style: const TextStyle(fontSize: 20, height: 1.6),
                ),
              ),
      ),
    ],
  );
  void _offset(int delta) {
    if (id == null) return;
    final features = widget.app.library.features;
    features.lyricOffsets[id!] = ((features.lyricOffsets[id!] ?? 0) + delta)
        .clamp(-30000, 30000);
    widget.app.library.saveFeatures();
    setState(() {});
  }
}
