import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../domain/models.dart';
import '../domain/music_share_link.dart';
import '../l10n/app_localizations.dart';
import '../logic/app_controller.dart';

/// Albums grouped by metadata can contain several releases. Let the sender
/// choose a source instead of silently sharing an arbitrary recording version.
class MusicShareButton extends StatelessWidget {
  const MusicShareButton({
    super.key,
    required this.app,
    required this.tracks,
    required this.kind,
    required this.title,
  });
  final AppController app;
  final List<Track> tracks;
  final MusicShareKind kind;
  final String title;

  @override
  Widget build(BuildContext context) {
    final sources = <String, List<Track>>{};
    for (final track in tracks.where((t) => t.source == TrackSource.torrent)) {
      sources
          .putIfAbsent(track.torrentHash?.toLowerCase() ?? '', () => [])
          .add(track);
    }
    final links = sources.values
        .map(
          (items) => MusicShareLink.fromTracks(items, kind: kind, title: title),
        )
        .whereType<MusicShareLink>()
        .toList();
    if (links.isEmpty) return const SizedBox.shrink();
    return OutlinedButton.icon(
      key: ValueKey('share-${kind.name}'),
      icon: const Icon(Icons.share_outlined, size: 18),
      label: Text(tr('Поделиться')),
      onPressed: () async {
        var link = links.first;
        if (links.length > 1) {
          final selected = await showDialog<MusicShareLink>(
            context: context,
            builder: (context) => SimpleDialog(
              title: Text(tr('Выбери раздачу')),
              children: [
                for (final option in links)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, option),
                    child: Text(
                      '${sources[option.hash]?.first.format ?? ''} · '
                      '${option.hash.substring(0, 12)}',
                    ),
                  ),
              ],
            ),
          );
          if (selected == null || !context.mounted) return;
          link = selected;
        }
        if (context.mounted) await showMusicShare(context, app, link);
      },
    );
  }
}

Future<void> showMusicShare(
  BuildContext context,
  AppController app,
  MusicShareLink link,
) async {
  final value = link.uri.toString();
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('Поделиться музыкой')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(link.title),
              const SizedBox(height: 12),
              Text(
                tr(
                  'Ссылка откроет Mumpa и скачает выбранную музыку. Уже скачанные файлы откроются сразу.',
                ),
              ),
              const SizedBox(height: 16),
              if (value.length < 1800)
                Center(
                  child: QrImageView(
                    data: value,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
                ),
              const SizedBox(height: 12),
              SelectableText(
                value,
                key: const Key('music-share-link'),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Закрыть')),
        ),
        if (Platform.isAndroid)
          TextButton.icon(
            icon: const Icon(Icons.share_outlined),
            label: Text(tr('Отправить')),
            onPressed: () => app.run(tr('Поделиться музыкой'), () async {
              await const MethodChannel('app.mumpa/device').invokeMethod<void>(
                'shareText',
                {'text': '${link.title}\n$value', 'title': link.title},
              );
            }),
          ),
        FilledButton.icon(
          key: const Key('copy-music-link'),
          icon: const Icon(Icons.copy_rounded),
          label: Text(tr('Копировать ссылку')),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            app.reportMessage(tr('Ссылка скопирована.'));
            if (context.mounted) Navigator.pop(context);
          },
        ),
      ],
    ),
  );
}
