import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../logic/app_controller.dart';
import 'theme.dart';

Future<void> showAddMusic(BuildContext context, AppController app) async {
  final link = TextEditingController();
  final action = await showDialog<String>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Добавить музыку',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Собери свою коллекцию из локальных альбомов и торрент-ссылок.',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 24),
              _SourceOption(
                icon: Icons.folder_open_rounded,
                title: 'Папка с альбомами',
                subtitle: 'Импортировать все аудиофайлы из папки',
                onTap: () => Navigator.pop(context, 'folder'),
              ),
              const SizedBox(height: 10),
              _SourceOption(
                icon: Icons.audio_file_outlined,
                title: 'Музыкальные файлы',
                subtitle: 'MP3, FLAC, M4A, OGG, WAV и другие',
                onTap: () => Navigator.pop(context, 'files'),
              ),
              const SizedBox(height: 10),
              _SourceOption(
                icon: Icons.file_open_outlined,
                title: 'Файл .torrent',
                subtitle: 'Выбрать треки и слушать без полной загрузки',
                onTap: () => Navigator.pop(context, 'torrent'),
              ),
              const SizedBox(height: 24),
              const Text(
                'MAGNET / TORRENT URL',
                style: TextStyle(
                  color: muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('torrent-link-input'),
                controller: link,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: 'magnet:?xt=urn:btih:… или https://…/album.torrent',
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('inspect-torrent'),
                  onPressed: () {
                    if (link.text.trim().isNotEmpty) {
                      Navigator.pop(context, 'link');
                    }
                  },
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('Открыть торрент'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (action == null) return;
  TorrentInfo? torrent;
  switch (action) {
    case 'folder':
      await app.importFolder();
    case 'files':
      await app.importFiles();
    case 'torrent':
      torrent = await app.pickTorrent();
    case 'link':
      torrent = await app.inspectTorrent(link.text.trim());
  }
  if (torrent != null && context.mounted) {
    await selectTorrent(
      context,
      app,
      torrent,
      link: action == 'link' ? link.text.trim() : null,
    );
  }
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF333D34)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: accent, size: 26),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: muted),
        ],
      ),
    ),
  );
}

Future<void> selectTorrent(
  BuildContext context,
  AppController app,
  TorrentInfo info, {
  String? link,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _TorrentDialog(app: app, info: info, link: link),
  );
}

class _TorrentDialog extends StatefulWidget {
  const _TorrentDialog({required this.app, required this.info, this.link});
  final AppController app;
  final TorrentInfo info;
  final String? link;
  @override
  State<_TorrentDialog> createState() => _TorrentDialogState();
}

class _TorrentDialogState extends State<_TorrentDialog> {
  late final List<TorrentFile> files = widget.info.files
      .where((f) => isAudioPath(f.path))
      .toList();
  late final Set<int> selected = files.map((f) => f.index).toSet();
  late final album = TextEditingController(text: widget.info.title);
  final artist = TextEditingController();
  @override
  void dispose() {
    album.dispose();
    artist.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 680,
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Треки из торрента',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (files.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('В этом торренте нет поддерживаемых аудиофайлов.'),
              ),
            if (files.isNotEmpty) ...[
              const SizedBox(height: 14),
              TextField(
                controller: album,
                decoration: const InputDecoration(labelText: 'Альбом'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: artist,
                decoration: const InputDecoration(
                  labelText: 'Исполнитель',
                  hintText:
                      'Можно указать сейчас; теги прочитаются после скачивания',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${files.length} аудиофайлов · ${formatBytes(files.fold<int>(0, (a, b) => a + b.bytes))}',
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      if (selected.length == files.length) {
                        selected.clear();
                      } else {
                        selected.addAll(files.map((f) => f.index));
                      }
                    }),
                    child: Text(
                      selected.length == files.length
                          ? 'Снять всё'
                          : 'Выбрать всё',
                    ),
                  ),
                ],
              ),
              const Divider(),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: files.length,
                  itemBuilder: (_, i) => CheckboxListTile(
                    value: selected.contains(files[i].index),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        selected.add(files[i].index);
                      } else {
                        selected.remove(files[i].index);
                      }
                    }),
                    title: Text(
                      files[i].path,
                      style: const TextStyle(fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      formatBytes(files[i].bytes),
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: selected.isEmpty
                      ? null
                      : () async {
                          Navigator.pop(context);
                          await widget.app.addTorrent(
                            widget.info,
                            selected,
                            link: widget.link,
                            album: album.text,
                            artist: artist.text,
                          );
                        },
                  icon: const Icon(Icons.library_add_rounded),
                  label: Text('Добавить ${selected.length} треков'),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
