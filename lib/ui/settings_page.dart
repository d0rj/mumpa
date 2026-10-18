part of 'pages.dart';

enum _SettingsSection {
  playback(
    'Воспроизведение',
    'Радио после окончания очереди',
    Icons.radio_rounded,
  ),
  sources(
    'Источники музыки',
    'Готовый каталог, RuTracker и дополнительные источники',
    Icons.travel_explore_rounded,
  ),
  torrent(
    'Торрент и сеть',
    'Движок, TorrServer и сетевой интерфейс',
    Icons.lan_outlined,
  ),
  downloads(
    'Загрузки и офлайн',
    'Автоскачивание, параллельные загрузки и лимит места',
    Icons.download_for_offline_outlined,
  ),
  metadata(
    'Обложки и кеш',
    'Место для метаданных и обложек, очистка кеша',
    Icons.album_outlined,
  ),
  windowsPlayer(
    'Плеер в Windows',
    'Кнопки мультимедиа, панель задач и работа в трее',
    Icons.desktop_windows_outlined,
  ),
  about(
    'О приложении',
    'Обновления, лицензии и расположение медиатеки',
    Icons.info_outline,
  );

  const _SettingsSection(this.title, this.description, this.icon);
  final String title;
  final String description;
  final IconData icon;
}

class _OfflineUsage extends StatefulWidget {
  const _OfflineUsage({required this.app});
  final AppController app;
  @override
  State<_OfflineUsage> createState() => _OfflineUsageState();
}

class _OfflineUsageState extends State<_OfflineUsage> {
  late Future<OfflineStorageUsage> _usage;
  Set<String> _paths = {};

  @override
  void initState() {
    super.initState();
    _refresh();
    widget.app.library.addListener(_libraryChanged);
  }

  void _refresh() {
    _paths = widget.app.library.offlineTracks.map((t) => t.cachedPath!).toSet();
    _usage = widget.app.downloads.storageUsage();
  }

  void _libraryChanged() {
    final paths = widget.app.library.offlineTracks
        .map((t) => t.cachedPath!)
        .toSet();
    if (paths.length != _paths.length || !paths.containsAll(_paths)) {
      setState(_refresh);
    }
  }

  @override
  void dispose() {
    widget.app.library.removeListener(_libraryChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<OfflineStorageUsage>(
    future: _usage,
    builder: (context, snapshot) {
      final usage = snapshot.data;
      final limit = widget.app.downloads.limitBytes;
      final fraction = usage == null || limit <= 0 ? 0.0 : usage.bytes / limit;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  usage == null
                      ? snapshot.hasError
                            ? 'Не удалось прочитать размер загрузок'
                            : 'Подсчитываем скачанные треки…'
                      : 'Скачанные треки: ${formatBytes(usage.bytes)} из ${formatBytes(limit)} · ${(fraction * 100).toStringAsFixed(1)}%',
                  key: const ValueKey('offline-storage-usage'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Обновить размер загрузок',
                onPressed: () => setState(_refresh),
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
          LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            backgroundColor: const Color(0xFF2E3A2C),
            color: fraction > 1 ? Colors.orangeAccent : accent,
            minHeight: 6,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 8),
          Text(
            '${usage == null ? '' : 'Файлов: ${usage.files} · '}Только треки, скачанные Mumpa. Добавленная с диска музыка не учитывается. Незавершённые загрузки также используют лимит.',
            style: const TextStyle(color: muted, fontSize: 11),
          ),
        ],
      );
    },
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app});
  final AppController app;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _loadedSection;

  @override
  void initState() {
    super.initState();
    _refreshSelectedSection();
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) _loadedSection = null;
    _refreshSelectedSection();
  }

  void _refreshSelectedSection() {
    final section = widget.app.settingsSection;
    if (section == _loadedSection) return;
    _loadedSection = section;
    if (section == _SettingsSection.metadata.name) {
      // Refresh on entry; playback notifications do not rescan the cache.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.app.settingsSection == section) {
          unawaited(widget.app.refreshMetadataCache());
        }
      });
    } else if (section == _SettingsSection.torrent.name && Platform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.app.settingsSection == section) {
          unawaited(widget.app.refreshTorrentNetworks());
        }
      });
    }
  }

  late final server = TextEditingController(
    text: widget.app.library.settings['serverUrl'] as String? ?? '',
  );
  late final source = TextEditingController(
    text: widget.app.library.settings['indexerUrl'] as String? ?? '',
  );
  late final apiKey = TextEditingController(
    text: widget.app.library.settings['indexerKey'] as String? ?? '',
  );
  late final limit = TextEditingController(
    text: '${widget.app.library.settings['cacheLimitMb'] ?? 4096}',
  );
  @override
  void dispose() {
    server.dispose();
    source.dispose();
    apiKey.dispose();
    limit.dispose();
    super.dispose();
  }

  List<_SettingsSection> get _sections => [
    for (final section in _SettingsSection.values)
      if (section != _SettingsSection.windowsPlayer ||
          widget.app.windowsPlayer != null)
        section,
  ];

  @override
  Widget build(BuildContext context) {
    final section = _sections
        .where((value) => value.name == widget.app.settingsSection)
        .firstOrNull;
    return LayoutBuilder(
      builder: (_, constraints) {
        if (section == null) return _overview();
        if (constraints.maxWidth < 900) return _sectionPage(section);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 238,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 26, 8, 24),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      'НАСТРОЙКИ',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.4,
                        color: muted,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  for (final item in _sections)
                    ListTile(
                      key: ValueKey('settings-nav-${item.name}'),
                      leading: Icon(item.icon, size: 20),
                      title: Text(
                        item.title,
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: item == section,
                      selectedColor: accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      onTap: () => widget.app.setSettingsSection(item.name),
                    ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _sectionPage(section)),
          ],
        );
      },
    );
  }

  Widget _overview() => _PageBody(
    children: [
      const SectionTitle('Настройки', subtitle: 'Сделай Mumpa своей'),
      const Text(
        'Выбери раздел, чтобы изменить нужные параметры.',
        style: TextStyle(color: muted, fontSize: 12),
      ),
      const SizedBox(height: 22),
      LayoutBuilder(
        builder: (_, constraints) {
          final columns = constraints.maxWidth >= 700 ? 2 : 1;
          final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final section in _sections)
                SizedBox(
                  width: width,
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      key: ValueKey('settings-section-${section.name}'),
                      contentPadding: const EdgeInsets.all(16),
                      leading: Icon(section.icon, color: accent),
                      title: Text(
                        section.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          section.description,
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => widget.app.setSettingsSection(section.name),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );

  Widget _sectionPage(_SettingsSection section) => _PageBody(
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('settings-back'),
          onPressed: widget.app.back,
          icon: const Icon(Icons.arrow_back_rounded, size: 18),
          label: const Text('Назад'),
        ),
      ),
      SectionTitle(section.title, subtitle: section.description),
      _panel(switch (section) {
        _SettingsSection.playback => _playbackControls(),
        _SettingsSection.sources => _sourceControls(),
        _SettingsSection.torrent => _engineControls(),
        _SettingsSection.downloads => _downloadControls(),
        _SettingsSection.metadata => _metadataControls(),
        _SettingsSection.windowsPlayer => _windowsControls(),
        _SettingsSection.about => _aboutControls(),
      }),
    ],
  );

  List<Widget> _playbackControls() => [
    SwitchListTile.adaptive(
      key: const ValueKey('radio-autoplay'),
      contentPadding: EdgeInsets.zero,
      title: const Text('Продолжать музыку после очереди'),
      subtitle: const Text('Подбирать треки тех же и похожих исполнителей'),
      value: widget.app.playback.radioEnabled,
      onChanged: (value) =>
          unawaited(widget.app.playback.setRadioEnabled(value)),
    ),
    const SizedBox(height: 12),
    const Text(
      'Следующие треки готовятся заранее. Недоступные раздачи пропускаются. '
      'Исходный плейлист сохраняется; повтор и таймер сна имеют приоритет.',
      style: TextStyle(color: muted, fontSize: 12),
    ),
  ];

  Widget _panel(List<Widget> children) => Align(
    alignment: Alignment.topLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );

  List<Widget> _windowsControls() => [
    if (widget.app.windowsPlayer != null)
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Крестик скрывает Mumpa в трее, и музыка продолжает играть. '
              'Нажми значок в трее, чтобы вернуть окно. '
              'Кнопки на колонках и под превью на панели задач управляют плеером.',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('quit-mumpa'),
              onPressed: widget.app.windowsPlayer!.available
                  ? () async {
                      try {
                        await widget.app.windowsPlayer!.requestQuit();
                      } catch (_) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Не удалось завершить Mumpa. Попробуй ещё раз.',
                              ),
                            ),
                          );
                        }
                      }
                    }
                  : null,
              icon: const Icon(Icons.exit_to_app_rounded, size: 18),
              label: const Text('Завершить Mumpa'),
            ),
            if (!widget.app.windowsPlayer!.available)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Управление через Windows сейчас недоступно.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
  ];

  List<Widget> _sourceControls() => [
    const SectionTitle('Музыка сразу после установки'),
    const Text(
      '«Автоматически» ищет музыку в Knaben и RuTor без аккаунта, '
      'Jackett и FlareSolverr. Поисковые запросы отправляются этим каталогам. '
      'Наличие раздачи в поиске не гарантирует доступных пиров.',
      style: TextStyle(color: muted, fontSize: 12),
    ),
    const SizedBox(height: 12),
    SearchProviderPicker(app: widget.app),
    const SizedBox(height: 22),
    ExpansionTile(
      key: const PageStorageKey('settings-custom-sources'),
      title: const Text('Дополнительно: свой Jackett / Prowlarr'),
      subtitle: const Text('Для собственных трекеров и серверов'),
      tilePadding: EdgeInsets.zero,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('Jackett · дополнительный каталог'),
              if (Platform.isWindows)
                FilledButton.icon(
                  onPressed: widget.app.busy == null
                      ? () async {
                          await setupJackett(
                            context,
                            widget.app,
                            embedded: true,
                          );
                          source.text =
                              widget.app.library.settings['indexerUrl']
                                  as String? ??
                              '';
                          apiKey.text =
                              widget.app.library.settings['indexerKey']
                                  as String? ??
                              '';
                        }
                      : null,
                  icon: const Icon(Icons.settings_rounded, size: 18),
                  label: const Text('Запустить Jackett и настроить RuTracker'),
                ),
              if (Platform.isWindows) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: widget.app.busy == null
                      ? widget.app.prepareCloudflare
                      : null,
                  icon: const Icon(Icons.verified_user_outlined, size: 18),
                  label: Text(
                    widget.app.cloudflareEnabled
                        ? 'FlareSolverr подключён · проверить'
                        : 'Настроить FlareSolverr для Cloudflare',
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Если Jackett сообщает Empty cookies returned by FlareSolverr, выбери «Автоматически» или войди в RuTracker напрямую ниже. Для поиска через Mumpa не нужно настраивать cookies вручную.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
              const SizedBox(height: 14),
              const Text(
                'Добавь RuTracker.org в Jackett и сохрани аккаунт. Можно использовать встроенный Jackett на Windows или подключить свой сервер Jackett/Prowlarr по адресу и API key.',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const PageStorageKey('settings-jackett-url'),
                controller: source,
                decoration: const InputDecoration(
                  labelText: 'Адрес Jackett или URL Torznab API',
                  hintText:
                      'http://localhost:9117/api/v2.0/indexers/all/results/torznab/api',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const PageStorageKey('settings-jackett-key'),
                controller: apiKey,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'API key'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () =>
                    widget.app.saveIndexer(source.text, apiKey.text),
                child: const Text('Сохранить и проверить подключение'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Использовать Jackett для поиска',
                  style: TextStyle(fontSize: 13),
                ),
                value: widget.app.searchProvider == 'torznab',
                onChanged: (value) => widget.app.setSearchProvider(
                  value ? 'torznab' : 'automatic',
                ),
              ),
            ],
          ),
        ),
      ],
    ),
    const SectionTitle('Прямой доступ к RuTracker'),
    Text(
      widget.app.catalog.username == null
          ? 'Войди в свой аккаунт для поиска исполнителей и альбомов.'
          : 'Выполнен вход: ${widget.app.catalog.username}',
      style: const TextStyle(color: muted),
    ),
    const SizedBox(height: 12),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: () => widget.app.connectCatalog(),
          icon: const Icon(Icons.login_rounded, size: 18),
          label: const Text('Войти в RuTracker'),
        ),
        TextButton(
          onPressed: () => widget.app.connectCatalog(login: false),
          child: const Text('Открыть сайт'),
        ),
        if (widget.app.catalog.username != null)
          TextButton(
            onPressed: () async {
              await widget.app.catalog.logout();
              await widget.app.refreshCatalog();
            },
            child: const Text('Выйти'),
          ),
      ],
    ),
    const SizedBox(height: 12),
    DropdownButtonFormField<String>(
      initialValue: widget.app.catalog.base.toString(),
      decoration: const InputDecoration(labelText: 'Зеркало RuTracker'),
      items: RuTrackerService.mirrors
          .map(
            (url) =>
                DropdownMenuItem(value: url, child: Text(Uri.parse(url).host)),
          )
          .toList(),
      onChanged: (url) async {
        if (url == null) return;
        await widget.app.catalog.setMirror(url);
        await widget.app.library.setSetting('rutrackerMirror', url);
        await widget.app.refreshCatalog();
      },
    ),
    const SizedBox(height: 20),
  ];

  List<Widget> _engineControls() => [
    const SectionTitle('Торрент-движок'),
    if (Platform.isWindows) ...[
      DropdownButtonFormField<String>(
        key: ValueKey(widget.app.torrentInterface),
        initialValue: widget.app.torrentInterface,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Интерфейс встроенного торрент-движка',
        ),
        items: [
          const DropdownMenuItem(
            value: '',
            child: Text('Системный маршрут (по умолчанию)'),
          ),
          for (final name in {
            ...widget.app.torrentNetworks.map((n) => n.name),
            if (widget.app.torrentInterface.isNotEmpty)
              widget.app.torrentInterface,
          })
            DropdownMenuItem(value: name, child: Text(name)),
        ],
        onChanged: widget.app.busy == null
            ? (name) {
                if (name != null) {
                  unawaited(widget.app.saveTorrentInterface(name));
                }
              }
            : null,
      ),
      const SizedBox(height: 8),
      const Text(
        'Выбор Wi-Fi или Ethernet может отправлять торрент-трафик напрямую: '
        'трекеры и пиры увидят IP провайдера. Системный маршрут учитывает VPN. '
        'Настройка применяется после перезапуска Mumpa. '
        'Другой интерфейс не будет выбран автоматически.',
        style: TextStyle(color: muted, fontSize: 12),
      ),
      TextButton.icon(
        onPressed: widget.app.refreshTorrentNetworks,
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('Обновить список интерфейсов'),
      ),
      const SizedBox(height: 12),
    ],
    const Text(
      'Встроенный движок работает автоматически. Можно подключить свой TorrServer — например, на домашнем сервере.',
      style: TextStyle(color: muted),
    ),
    const SizedBox(height: 14),
    TextField(
      controller: server,
      decoration: const InputDecoration(
        labelText: 'Внешний TorrServer (необязательно)',
        hintText: 'http://192.168.1.10:8090',
      ),
    ),
    const SizedBox(height: 12),
    Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        FilledButton(
          onPressed: () async {
            final url = server.text.trim();
            final uri = Uri.tryParse(url);
            if (url.isNotEmpty &&
                (uri == null ||
                    !{'http', 'https'}.contains(uri.scheme) ||
                    uri.host.isEmpty)) {
              widget.app.reportError('Укажите корректный HTTP/HTTPS URL.');
              return;
            }
            await widget.app.library.setSetting('serverUrl', url);
            await widget.app.checkEngine();
          },
          child: const Text('Сохранить и проверить'),
        ),
        TextButton(
          onPressed: widget.app.checkEngine,
          child: const Text('Проверить движок'),
        ),
      ],
    ),
    if (widget.app.engineVersion != null)
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          'Подключён: ${widget.app.engineVersion}',
          style: const TextStyle(color: accent, fontSize: 12),
        ),
      ),
  ];

  List<Widget> _downloadControls() => [
    const SectionTitle('Офлайн и кеш'),
    DropdownButtonFormField<int>(
      key: ValueKey('prefetch-tracks-${widget.app.prefetch.count}'),
      initialValue: widget.app.prefetch.count,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Загружать следующие треки заранее',
      ),
      items: [
        for (var count = 0; count <= 10; count++)
          DropdownMenuItem(
            value: count,
            child: Text(count == 0 ? 'Отключено' : '$count'),
          ),
      ],
      onChanged: (value) {
        if (value != null) unawaited(widget.app.prefetch.setCount(value));
      },
    ),
    const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        'По умолчанию 3 следующих незагруженных трека из текущей очереди. '
        'Офлайн-копии пропускаются. При паузе подготовка приостанавливается; '
        'готовые файлы сохраняются.',
        style: TextStyle(color: muted, fontSize: 11),
      ),
    ),
    const Text(
      'Лайкнутые и скачанные треки не удаляются автоматически или при удалении альбома. '
      'Офлайн-копию можно удалить только вручную с подтверждением. '
      'Лимит места останавливает новые загрузки, сохраняя существующие файлы.',
      style: TextStyle(color: muted),
    ),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text(
        'Скачивать прослушиваемые треки',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      subtitle: const Text(
        'Автоматически сохранять торрент-треки для офлайн',
        style: TextStyle(fontSize: 11, color: muted),
      ),
      value: widget.app.library.settings['autoCache'] == true,
      onChanged: (v) => widget.app.library.setSetting('autoCache', v),
    ),
    const SizedBox(height: 12),
    DropdownButtonFormField<int>(
      key: ValueKey(
        'download-concurrency-${widget.app.downloads.maxConcurrentDownloads}',
      ),
      initialValue: widget.app.downloads.maxConcurrentDownloads,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Одновременные загрузки треков',
      ),
      items: [
        for (final count in [1, 2, 3, 4, 5, 6])
          DropdownMenuItem(
            value: count,
            child: Text(count == 1 ? '1 · по очереди' : '$count · параллельно'),
          ),
      ],
      onChanged: widget.app.busy != null
          ? null
          : (value) {
              if (value != null) {
                unawaited(widget.app.setDownloadConcurrency(value));
              }
            },
    ),
    const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        'По умолчанию 3. Прослушиваемый трек получает место в очереди первым. Пауза сохраняет загруженную часть файла.',
        style: TextStyle(color: muted, fontSize: 11),
      ),
    ),
    TextField(
      controller: limit,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: 'Лимит офлайн-загрузок, МБ',
        hintText: '4096',
      ),
    ),
    const SizedBox(height: 14),
    _OfflineUsage(app: widget.app),
    const SizedBox(height: 12),
    TextButton(
      onPressed: () async {
        final value = int.tryParse(limit.text);
        if (value != null && value >= 64) {
          await widget.app.library.setSetting('cacheLimitMb', value);
        }
      },
      child: const Text('Сохранить лимит'),
    ),
  ];

  List<Widget> _metadataControls() => [
    const SectionTitle('Обложки и музыкальные метаданные'),
    const Text(
      'MusicBrainz помогает сопоставлять исполнителей и альбомы. '
      'Cover Art Archive предоставляет обложки. Данные сохраняются на диске; '
      'при заполнении кеша удаляются самые старые записи.',
      style: TextStyle(color: muted, fontSize: 12),
    ),
    const SizedBox(height: 12),
    DropdownButtonFormField<int>(
      key: ValueKey(
        'metadata-cache-${widget.app.library.settings['metadataCacheMb'] ?? 256}',
      ),
      initialValue:
          widget.app.library.settings['metadataCacheMb'] as int? ?? 256,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Лимит кеша обложек и метаданных',
      ),
      items: [
        for (final mb in {
          64,
          128,
          256,
          512,
          1024,
          widget.app.library.settings['metadataCacheMb'] as int? ?? 256,
        }.toList()..sort())
          DropdownMenuItem(value: mb, child: Text('$mb МБ')),
      ],
      onChanged: widget.app.cacheBusy
          ? null
          : (value) {
              if (value != null) {
                unawaited(widget.app.setMetadataCacheLimit(value));
              }
            },
    ),
    const SizedBox(height: 12),
    if (widget.app.cacheStats != null)
      Text(
        '${formatBytes(widget.app.cacheStats!.bytes)} из '
        '${formatBytes(widget.app.cacheStats!.maxBytes)} · '
        '${widget.app.cacheStats!.count} записей',
        style: const TextStyle(color: muted, fontSize: 12),
      ),
    Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        TextButton.icon(
          key: const ValueKey('clear-metadata-cache'),
          onPressed: widget.app.cacheBusy
              ? null
              : widget.app.clearMetadataCache,
          icon: const Icon(Icons.delete_sweep_outlined, size: 18),
          label: const Text('Очистить кеш'),
        ),
        TextButton(
          onPressed: widget.app.cacheBusy
              ? null
              : widget.app.refreshMetadataCache,
          child: const Text('Обновить размер'),
        ),
      ],
    ),
  ];

  List<Widget> _aboutControls() => [
    AppUpdatePanel(
      updates: widget.app.updates,
      quit: () async {
        final shell = widget.app.windowsPlayer;
        if (shell == null || !shell.available) {
          throw const FormatException(
            'Перезапуск недоступен. Заверши Mumpa и повтори установку.',
          );
        }
        await shell.requestQuit();
      },
      autoCheck: widget.app.library.settings['checkAppUpdates'] != false,
      onAutoCheck: (value) =>
          unawaited(widget.app.library.setSetting('checkAppUpdates', value)),
    ),
    const SizedBox(height: 24),
    const SectionTitle('Mumpa'),
    const Text(
      'Музыка из твоих файлов и источников.\nДемо Mumpa Sessions — оригинальные синтезированные фрагменты.\nFlutter · media_kit · TorrServer MatriX.145.2',
      style: TextStyle(color: muted, fontSize: 12),
    ),
    const SizedBox(height: 12),
    TextButton(
      onPressed: () => showLicensePage(
        context: context,
        applicationName: 'Mumpa',
        applicationVersion: widget.app.updates.currentVersion,
        applicationLegalese:
            'GPL-3.0 · TorrServer: github.com/YouROK/TorrServer, MatriX.145.2\nEngine source: commit bb3f4468d38a96f4df563f28c9fd4ccc3b2b37a9',
      ),
      child: const Text('Лицензии компонентов'),
    ),
    const SizedBox(height: 12),
    SelectableText(
      'Библиотека: ${widget.app.library.root.path}',
      style: const TextStyle(fontSize: 10, color: muted),
    ),
    const SizedBox(height: 8),
    const Text(
      'Избранное и настройки сохраняются отдельно от приложения. '
      'Резервные копии за последние 7 дней находятся в подпапке backups. '
      'Обновление и очистка кеша сохраняют эти данные.',
      style: TextStyle(fontSize: 11, color: muted),
    ),
    if (Platform.isAndroid)
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'Импорт на Android сохраняет копии в приватной папке приложения.',
          style: TextStyle(color: muted, fontSize: 11),
        ),
      ),
  ];
}
