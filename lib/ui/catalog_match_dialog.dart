import 'package:flutter/material.dart';

import '../data/catalog_repository.dart';
import '../data/source_operation.dart';
import '../domain/catalog_matching.dart';
import '../domain/models.dart';
import '../domain/music_metadata.dart';
import '../l10n/app_localizations.dart';
import '../logic/app_controller.dart';

Future<void> showCatalogMatchDialog(
  BuildContext context,
  AppController app,
  Track track,
) => showDialog<void>(
  context: context,
  builder: (_) => _CatalogMatchDialog(app, track),
);

class _CatalogMatchDialog extends StatefulWidget {
  const _CatalogMatchDialog(this.app, this.track);
  final AppController app;
  final Track track;
  @override
  State<_CatalogMatchDialog> createState() => _CatalogMatchDialogState();
}

class _CatalogMatchDialogState extends State<_CatalogMatchDialog> {
  final _operation = SourceOperation();
  CatalogMatchResult? _result;
  String? _error;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.app.musicCatalog.match(
        widget.track,
        operation: _operation,
      );
      if (mounted) setState(() => _result = result);
    } catch (_) {
      if (mounted) {
        setState(() => _error = tr('Музыкальный каталог сейчас недоступен.'));
      }
    }
  }

  Future<void> _save(CatalogMatch? match) async {
    setState(() => _saving = true);
    try {
      MusicRecording? recording;
      if (match != null) {
        recording = await widget.app.musicCatalog.details(
          match.recording,
          operation: _operation,
        );
      }
      _operation.check();
      final saved = await widget.app.library.setCatalogLink(
        widget.track.id,
        recording == null
            ? null
            : TrackCatalogLink(
                recording: recording,
                matchedAt: DateTime.now().toUtc(),
                manual: true,
                evidence: match!.evidence,
              ),
        expectedEvidenceKey: widget.track.catalogEvidenceKey,
      );
      if (!saved) throw StateError('Track changed');
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = tr(
            'Не удалось сохранить привязку. Трек мог измениться; открой окно заново.',
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _operation.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final saved = widget.app.library.byId(widget.track.id)?.catalogLink;
    final result = _result;
    return AlertDialog(
      title: Text(tr('Привязка к каталогу')),
      content: SizedBox(
        width: 620,
        height: (MediaQuery.sizeOf(context).height * .55).clamp(180, 440),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.track.artist} — ${widget.track.title}'),
            if (saved != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${tr('Сохранено')}: ${saved.recording.artist} — ${saved.recording.title}\n'
                  '${saved.recording.provider == 'deezer' ? 'Deezer' : 'MusicBrainz'} · '
                  '${saved.manual ? tr('Выбрано вручную') : tr('Совпали метаданные')}',
                ),
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (result != null && result.unavailableProviders.isNotEmpty)
              Text(
                tr('Часть каталогов недоступна: {0}', [
                  result.unavailableProviders.join(', '),
                ]),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: result == null && _error == null
                  ? const Center(child: CircularProgressIndicator())
                  : result == null || result.matches.isEmpty
                  ? Center(
                      child: Text(
                        tr(
                          'Подходящие записи не найдены. Проверь метаданные трека.',
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: result.matches.length,
                      itemBuilder: (context, i) {
                        final match = result.matches[i];
                        final recording = match.recording;
                        return ListTile(
                          title: Text(
                            '${recording.artist} — ${recording.title}',
                          ),
                          subtitle: Text(
                            [
                              recording.albumTitles.take(2).join(' · '),
                              '${recording.provider == 'deezer' ? 'Deezer' : 'MusicBrainz'} · '
                                  '${recording.durationMs > 0 ? formatTime(Duration(milliseconds: recording.durationMs)) : '—'}',
                              match.conflicts.isEmpty
                                  ? tr('Метаданные согласуются')
                                  : tr('Есть различия: {0}', [
                                      match.conflicts.map(_field).join(', '),
                                    ]),
                            ].where((s) => s.isNotEmpty).join('\n'),
                          ),
                          isThreeLine: true,
                          trailing: IconButton(
                            icon: const Icon(Icons.link),
                            tooltip: tr('Связать с этой записью'),
                            onPressed: _saving ? null : () => _save(match),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (saved != null)
          TextButton(
            onPressed: _saving ? null : () => _save(null),
            child: Text(tr('Удалить привязку')),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(tr('Закрыть')),
        ),
      ],
    );
  }

  String _field(String key) => tr(switch (key) {
    'artist' => 'исполнитель',
    'title' => 'название',
    'duration' => 'длительность',
    'version' => 'версия',
    _ => key,
  });
}
