import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../data/lan_transfer.dart';
import '../data/profile_transfer.dart';
import '../domain/models.dart';
import '../logic/app_controller.dart';
import '../l10n/app_localizations.dart';
import 'theme.dart';

Future<void> showLanTransfer(BuildContext context, AppController app) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 650,
          height: 650,
          child: LanTransferView(app: app),
        ),
      ),
    );

class LanTransferView extends StatefulWidget {
  const LanTransferView({super.key, required this.app, this.embedded = false});
  final AppController app;
  final bool embedded;
  @override
  State<LanTransferView> createState() => _LanTransferViewState();
}

class _LanTransferViewState extends State<LanTransferView> {
  late final TextEditingController link;
  String? _pendingLink;
  late int _pendingRevision;
  LanTransferServer? server;
  LanTransferClient? client;
  String selection = 'profile', status = '', host = '';
  bool busy = false;
  int generation = 0;
  Timer? expiry;
  List<String> hosts = [];
  @override
  void initState() {
    super.initState();
    _pendingLink = widget.app.pendingTransferLink;
    _pendingRevision = widget.app.transferLinkRevision;
    link = TextEditingController(text: _pendingLink ?? '');
  }

  @override
  void didUpdateWidget(covariant LanTransferView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pending = widget.app.pendingTransferLink;
    final revision = widget.app.transferLinkRevision;
    if (pending == _pendingLink && revision == _pendingRevision) return;
    _pendingLink = pending;
    _pendingRevision = revision;
    if (pending == null) return;
    // A second Android pairing intent replaces an open form and cancels the
    // previous receive operation. Ordinary rebuilds preserve manual edits.
    ++generation;
    client?.close();
    client = null;
    busy = false;
    status = '';
    link.text = pending;
  }

  @override
  void dispose() {
    ++generation;
    expiry?.cancel();
    link.dispose();
    client?.close();
    final active = server;
    if (active != null) unawaited(active.close());
    super.dispose();
  }

  Future<void> _send() async {
    final current = ++generation;
    setState(() {
      busy = true;
      status = tr('Готовим передачу…');
    });
    try {
      final addresses = await LanTransferServer.localAddresses();
      if (addresses.isEmpty) {
        throw const FormatException(
          'Нет адреса локальной сети. Подключись к Wi-Fi или Ethernet.',
        );
      }
      final tracks = selection == 'all'
          ? widget.app.library.mediaTracks
          : selection.startsWith('playlist:')
          ? (widget.app.library
                        .playlistById(selection.substring(9))
                        ?.trackIds ??
                    [])
                .map(widget.app.library.byId)
                .whereType<Track>()
                .toList()
          : selection.startsWith('album:')
          ? widget.app.library.mediaAlbums
                .where((a) => a.id == selection.substring(6))
                .first
                .tracks
          : <Track>[];
      await widget.app.playback.saveSession();
      final started = await LanTransferServer.start(
        widget.app.library,
        tracks,
        cancelled: () => !mounted || current != generation,
      );
      if (!mounted || current != generation) {
        await started.close();
        return;
      }
      setState(() {
        server = started;
        hosts = addresses;
        host = addresses.first;
        status = tr(
          'Передача доступна 10 минут. Оба устройства должны быть в одной доверенной сети.',
        );
      });
      expiry?.cancel();
      expiry = Timer(const Duration(minutes: 10), () {
        if (mounted) {
          setState(() {
            server = null;
            status = tr('Срок передачи истёк.');
          });
        }
      });
    } catch (error) {
      if (mounted && current == generation) {
        setState(() => status = _message(error));
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  Future<void> _receive() async {
    final current = ++generation;
    final receiver = LanTransferClient.tryCreate(link.text.trim());
    if (receiver == null) {
      setState(
        () => status = tr('Нужна ссылка передачи Mumpa из локальной сети.'),
      );
      return;
    }
    client = receiver;
    setState(() {
      busy = true;
      status = tr('Проверяем передачу…');
    });
    try {
      final manifest = await receiver.preview();
      if (!mounted || current != generation) return;
      final profile = ProfileTransfer.decode(manifest['profile'] as String);
      final files = manifest['files'] as List;
      final bytes = files.fold<int>(
        0,
        (sum, row) => sum + (row['bytes'] as int),
      );
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Принять профиль и музыку?')),
          content: Text(
            tr(
              'Треков в профиле: {0}. Аудиофайлов: {1}, {2}. Импорт дополнит текущую медиатеку и сохранит резервную копию.',
              [profile.trackCount, files.length, formatBytes(bytes)],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Отмена')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'profile'),
              child: Text(tr('Только профиль')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'all'),
              child: Text(tr('Принять всё')),
            ),
          ],
        ),
      );
      if (choice == null || !mounted || current != generation) return;
      await receiver.receive(
        widget.app.library,
        manifest,
        includeAudio: choice == 'all',
        progress: (done, total) {
          if (mounted && current == generation) {
            setState(
              () => status = tr('Получено файлов: {0} из {1}', [done, total]),
            );
          }
        },
      );
      if (mounted && current == generation) {
        widget.app.pendingTransferLink = null;
        setState(() => status = tr('Профиль и выбранная музыка получены.'));
      }
    } catch (error) {
      if (mounted && current == generation) {
        setState(() => status = _message(error));
      }
    } finally {
      receiver.close();
      if (identical(client, receiver)) client = null;
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  String _message(Object error) => error is FormatException
      ? error.message
      : tr(
          'Передача не завершена. Проверь сеть и ссылку. Уже полученные файлы сохранены.',
        );
  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: widget.embedded,
    primary: widget.embedded ? false : null,
    physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        tr('Передача по Wi-Fi'),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      Text(tr('Отправить с этого устройства')),
      DropdownButtonFormField<String>(
        initialValue: selection,
        isExpanded: true,
        items: [
          DropdownMenuItem(value: 'profile', child: Text(tr('Только профиль'))),
          DropdownMenuItem(
            value: 'all',
            child: Text(tr('Вся доступная музыка')),
          ),
          for (final playlist in widget.app.library.mediaPlaylists)
            DropdownMenuItem(
              value: 'playlist:${playlist.id}',
              child: Text(playlist.name, overflow: TextOverflow.ellipsis),
            ),
          for (final album in widget.app.library.mediaAlbums)
            DropdownMenuItem(
              value: 'album:${album.id}',
              child: Text(
                '${album.artist} — ${album.title}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: busy || server != null
            ? null
            : (v) => setState(() => selection = v!),
      ),
      FilledButton(
        onPressed: busy || server != null ? null : _send,
        child: Text(tr('Создать QR-код передачи')),
      ),
      if (server != null) ...[
        DropdownButtonFormField<String>(
          initialValue: host,
          items: [
            for (final value in hosts)
              DropdownMenuItem(value: value, child: Text(value)),
          ],
          onChanged: (v) => setState(() => host = v!),
        ),
        Center(
          child: QrImageView(
            data: server!
                .address(host)
                .replace(scheme: 'mumpa-transfer')
                .toString(),
            size: 220,
            backgroundColor: Colors.white,
          ),
        ),
        TextButton.icon(
          onPressed: () => Clipboard.setData(
            ClipboardData(text: server!.address(host).toString()),
          ),
          icon: const Icon(Icons.copy),
          label: Text(tr('Скопировать ссылку')),
        ),
        TextButton(
          onPressed: () async {
            await server?.close();
            expiry?.cancel();
            if (mounted) setState(() => server = null);
          },
          child: Text(tr('Закрыть передачу')),
        ),
      ],
      const Divider(height: 28),
      Text(tr('Получить на это устройство')),
      TextField(
        controller: link,
        decoration: InputDecoration(
          labelText: tr('Ссылка с другого устройства'),
        ),
        keyboardType: TextInputType.url,
        autocorrect: false,
      ),
      FilledButton(
        onPressed: busy ? null : _receive,
        child: Text(tr('Проверить и принять')),
      ),
      if (busy) ...[
        const LinearProgressIndicator(),
        TextButton(
          onPressed: () {
            ++generation;
            client?.close();
            client = null;
            setState(() {
              busy = false;
              status = tr('Передача отменена.');
            });
          },
          child: Text(tr('Отмена')),
        ),
      ],
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(status, style: const TextStyle(color: muted)),
      ),
      Text(
        tr(
          'QR-код открывает Mumpa на Android. Можно также вставить ссылку вручную. Отправитель должен оставаться открытым; доступ через интернет не требуется.',
        ),
        style: const TextStyle(color: muted),
      ),
    ],
  );
}
