import '../l10n/app_localizations.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../data/app_update_service.dart';

class AppUpdatePanel extends StatelessWidget {
  const AppUpdatePanel({
    super.key,
    required this.updates,
    required this.quit,
    required this.autoCheck,
    required this.onAutoCheck,
  });
  final AppUpdateService updates;
  final Future<void> Function() quit;
  final bool autoCheck;
  final ValueChanged<bool> onAutoCheck;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: updates,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          updates.currentVersion.isEmpty
              ? tr("Обновления Mumpa")
              : 'Mumpa ${updates.currentVersion}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(tr("Проверять обновления при запуске")),
          value: autoCheck,
          onChanged: onAutoCheck,
        ),
        Text(trMessage(updates.status)),
        if (updates.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              trMessage(updates.error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (updates.busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(
              value: updates.status.startsWith('Скачиваем')
                  ? updates.progress
                  : null,
            ),
          ),
        if (updates.received > 0 && updates.busy && updates.available != null)
          Text(
            tr("{0} / {1} МБ", [
              (updates.received / 1024 / 1024).toStringAsFixed(1),
              (updates.available!.bytes / 1024 / 1024).toStringAsFixed(1),
            ]),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('check-app-update'),
              onPressed: updates.busy ? null : updates.check,
              icon: const Icon(Icons.refresh),
              label: Text(tr("Проверить обновления")),
            ),
            if (updates.available != null && updates.downloaded == null)
              FilledButton.icon(
                key: const ValueKey('download-app-update'),
                onPressed: updates.busy ? null : updates.download,
                icon: const Icon(Icons.download),
                label: Text(tr("Скачать обновление")),
              ),
            if (updates.downloaded != null)
              FilledButton.icon(
                key: const ValueKey('install-app-update'),
                onPressed: updates.busy
                    ? null
                    : () => unawaited(updates.install(quit: quit)),
                icon: const Icon(Icons.system_update),
                label: Text(
                  Platform.isWindows
                      ? tr("Установить и перезапустить")
                      : tr("Установить обновление"),
                ),
              ),
            if (updates.busy && updates.status.startsWith('Скачиваем'))
              TextButton(
                onPressed: updates.cancelDownload,
                child: Text(tr("Отмена")),
              ),
          ],
        ),
        if (updates.downloaded != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(
              tr("Файл: {0}", [updates.downloaded!.path]),
              style: const TextStyle(fontSize: 11),
            ),
          ),
        if (Platform.isWindows)
          Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              tr(
                "Установка завершит воспроизведение и перезапустит Mumpa. Медиатека и настройки сохраняются.",
              ),
              style: TextStyle(fontSize: 12),
            ),
          ),
        if (Platform.isWindows)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              tr(
                "Публичные релизы скачиваются без авторизации. Для приватных релизов используется вход в GitHub CLI этого пользователя.",
              ),
              style: TextStyle(fontSize: 12),
            ),
          ),
        if (Platform.isAndroid &&
            updates.available?.androidSigning == 'ephemeral-debug-key')
          Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              tr(
                "Этот выпуск подписан временным ключом CI. Android может отклонить обновление поверх текущей установки. Для совместимых обновлений нужен постоянный ключ релиза.",
              ),
              style: TextStyle(fontSize: 12),
            ),
          ),
      ],
    ),
  );
}
