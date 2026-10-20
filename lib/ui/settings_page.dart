part of 'pages.dart';

enum _SettingsSection {
  playback(
    'Воспроизведение',
    'Эквалайзер, переходы, громкость, моно и радио',
    Icons.radio_rounded,
  ),
  language('Язык', 'Язык интерфейса приложения', Icons.language_rounded),
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
  profile(
    'Перенос профиля',
    'Экспорт и импорт избранного, плейлистов и настроек',
    Icons.sync_alt_rounded,
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
                            ? tr("Не удалось прочитать размер загрузок")
                            : tr("Подсчитываем скачанные треки…")
                      : tr("Скачанные треки: {0} из {1} · {2}%", [
                          formatBytes(usage.bytes),
                          formatBytes(limit),
                          (fraction * 100).toStringAsFixed(1),
                        ]),
                  key: const ValueKey('offline-storage-usage'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              IconButton(
                tooltip: tr("Обновить размер загрузок"),
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
            tr(
              "{0}Только треки, скачанные Mumpa. Добавленная с диска музыка не учитывается. Незавершённые загрузки также используют лимит.",
              [
                usage == null ? '' : tr("Файлов: {0} · ", [usage.files]),
              ],
            ),
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
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      tr("НАСТРОЙКИ"),
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
                        tr(item.title),
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
      SectionTitle(tr("Настройки"), subtitle: tr("Сделай Mumpa своей")),
      Text(
        tr("Выбери раздел, чтобы изменить нужные параметры."),
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
                        tr(section.title),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          tr(section.description),
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
          label: Text(tr("Назад")),
        ),
      ),
      SectionTitle(tr(section.title), subtitle: tr(section.description)),
      _panel(switch (section) {
        _SettingsSection.playback => _playbackControls(),
        _SettingsSection.language => _languageControls(),
        _SettingsSection.sources => _sourceControls(),
        _SettingsSection.torrent => _engineControls(),
        _SettingsSection.downloads => _downloadControls(),
        _SettingsSection.metadata => _metadataControls(),
        _SettingsSection.profile => _profileControls(),
        _SettingsSection.windowsPlayer => _windowsControls(),
        _SettingsSection.about => _aboutControls(),
      }),
    ],
  );

  List<Widget> _playbackControls() => [
    AudioSettings(app: widget.app),
    const Divider(height: 40),
    SwitchListTile.adaptive(
      key: const ValueKey('radio-autoplay'),
      contentPadding: EdgeInsets.zero,
      title: Text(tr("Продолжать музыку после очереди")),
      subtitle: Text(tr("Подбирать треки тех же и похожих исполнителей")),
      value: widget.app.playback.radioEnabled,
      onChanged: (value) =>
          unawaited(widget.app.playback.setRadioEnabled(value)),
    ),
    const SizedBox(height: 12),
    Text(
      tr(
        "Следующие треки готовятся заранее. Недоступные раздачи пропускаются. Исходный плейлист сохраняется; повтор и таймер сна имеют приоритет.",
      ),
      style: TextStyle(color: muted, fontSize: 12),
    ),
  ];

  List<Widget> _languageControls() => [
    DropdownButtonFormField<String>(
      key: ValueKey(
        'app-language-${widget.app.library.settings['language'] ?? 'ru'}',
      ),
      initialValue: widget.app.library.settings['language'] == 'en'
          ? 'en'
          : 'ru',
      decoration: InputDecoration(labelText: tr("Язык интерфейса")),
      items: [
        DropdownMenuItem(value: 'ru', child: Text(tr("Русский"))),
        DropdownMenuItem(value: 'en', child: Text('English')),
      ],
      onChanged: (value) {
        if (value != null) {
          unawaited(widget.app.library.setSetting('language', value));
        }
      },
    ),
    const SizedBox(height: 12),
    Text(
      tr(
        "Язык меняется сразу. Названия музыки и поисковые запросы сохраняются.",
      ),
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
            Text(
              tr(
                "Крестик скрывает Mumpa в трее, и музыка продолжает играть. Нажми значок в трее, чтобы вернуть окно. Кнопки на колонках и под превью на панели задач управляют плеером.",
              ),
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
                            SnackBar(
                              content: Text(
                                tr(
                                  "Не удалось завершить Mumpa. Попробуй ещё раз.",
                                ),
                              ),
                            ),
                          );
                        }
                      }
                    }
                  : null,
              icon: const Icon(Icons.exit_to_app_rounded, size: 18),
              label: Text(tr("Завершить Mumpa")),
            ),
            if (!widget.app.windowsPlayer!.available)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  tr("Управление через Windows сейчас недоступно."),
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
  ];

  List<Widget> _sourceControls() => [
    SectionTitle(tr("Музыка сразу после установки")),
    Text(
      tr(
        "«Автоматически» ищет музыку в Knaben и RuTor без аккаунта, Jackett и FlareSolverr. Поисковые запросы отправляются этим каталогам. Наличие раздачи в поиске не гарантирует доступных пиров.",
      ),
      style: TextStyle(color: muted, fontSize: 12),
    ),
    const SizedBox(height: 12),
    SearchProviderPicker(app: widget.app),
    const SizedBox(height: 22),
    ExpansionTile(
      key: const PageStorageKey('settings-custom-sources'),
      title: Text(tr("Дополнительно: свой Jackett / Prowlarr")),
      subtitle: Text(tr("Для собственных трекеров и серверов")),
      tilePadding: EdgeInsets.zero,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(tr("Jackett · дополнительный каталог")),
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
                  label: Text(tr("Запустить Jackett и настроить RuTracker")),
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
                        ? tr("FlareSolverr подключён · проверить")
                        : tr("Настроить FlareSolverr для Cloudflare"),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    "Если Jackett сообщает Empty cookies returned by FlareSolverr, выбери «Автоматически» или войди в RuTracker напрямую ниже. Для поиска через Mumpa не нужно настраивать cookies вручную.",
                  ),
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                tr(
                  "Добавь RuTracker.org в Jackett и сохрани аккаунт. Можно использовать встроенный Jackett на Windows или подключить свой сервер Jackett/Prowlarr по адресу и API key.",
                ),
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const PageStorageKey('settings-jackett-url'),
                controller: source,
                decoration: InputDecoration(
                  labelText: tr("Адрес Jackett или URL Torznab API"),
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
                child: Text(tr("Сохранить и проверить подключение")),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  tr("Использовать Jackett для поиска"),
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
    SectionTitle(tr("Прямой доступ к RuTracker")),
    Text(
      widget.app.catalog.username == null
          ? tr("Войди в свой аккаунт для поиска исполнителей и альбомов.")
          : tr("Выполнен вход: {0}", [widget.app.catalog.username]),
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
          label: Text(tr("Войти в RuTracker")),
        ),
        TextButton(
          onPressed: () => widget.app.connectCatalog(login: false),
          child: Text(tr("Открыть сайт")),
        ),
        if (widget.app.catalog.username != null)
          TextButton(
            onPressed: () async {
              await widget.app.catalog.logout();
              await widget.app.refreshCatalog();
            },
            child: Text(tr("Выйти")),
          ),
      ],
    ),
    const SizedBox(height: 12),
    DropdownButtonFormField<String>(
      initialValue: widget.app.catalog.base.toString(),
      decoration: InputDecoration(labelText: tr("Зеркало RuTracker")),
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
    SectionTitle(tr("Торрент-движок")),
    if (Platform.isWindows) ...[
      DropdownButtonFormField<String>(
        key: ValueKey(widget.app.torrentInterface),
        initialValue: widget.app.torrentInterface,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: tr("Интерфейс встроенного торрент-движка"),
        ),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(tr("Системный маршрут (по умолчанию)")),
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
      Text(
        tr(
          "Выбор Wi-Fi или Ethernet может отправлять торрент-трафик напрямую: трекеры и пиры увидят IP провайдера. Системный маршрут учитывает VPN. Настройка применяется после перезапуска Mumpa. Другой интерфейс не будет выбран автоматически.",
        ),
        style: TextStyle(color: muted, fontSize: 12),
      ),
      TextButton.icon(
        onPressed: widget.app.refreshTorrentNetworks,
        icon: const Icon(Icons.refresh, size: 16),
        label: Text(tr("Обновить список интерфейсов")),
      ),
      const SizedBox(height: 12),
    ],
    Text(
      tr(
        "Встроенный движок работает автоматически. Можно подключить свой TorrServer — например, на домашнем сервере.",
      ),
      style: TextStyle(color: muted),
    ),
    const SizedBox(height: 14),
    TextField(
      controller: server,
      decoration: InputDecoration(
        labelText: tr("Внешний TorrServer (необязательно)"),
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
              widget.app.reportError(tr("Укажите корректный HTTP/HTTPS URL."));
              return;
            }
            await widget.app.library.setSetting('serverUrl', url);
            await widget.app.checkEngine();
          },
          child: Text(tr("Сохранить и проверить")),
        ),
        TextButton(
          onPressed: widget.app.checkEngine,
          child: Text(tr("Проверить движок")),
        ),
      ],
    ),
    if (widget.app.engineVersion != null)
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          tr("Подключён: {0}", [widget.app.engineVersion]),
          style: const TextStyle(color: accent, fontSize: 12),
        ),
      ),
  ];

  List<Widget> _downloadControls() => [
    SectionTitle(tr("Офлайн и кеш")),
    DropdownButtonFormField<String>(
      key: ValueKey('download-quality-${widget.app.downloads.quality}'),
      initialValue: widget.app.downloads.quality,
      isExpanded: true,
      decoration: InputDecoration(labelText: tr("Качество скачивания")),
      items: [
        DropdownMenuItem(
          value: 'original',
          child: Text(tr("Выбранная версия · оригинал")),
        ),
        DropdownMenuItem(
          value: 'lossless',
          child: Text(tr("Предпочитать lossless")),
        ),
        DropdownMenuItem(
          value: 'compact',
          child: Text(tr("Предпочитать компактный формат")),
        ),
      ],
      onChanged: (value) {
        if (value != null) {
          unawaited(widget.app.library.setSetting('downloadQuality', value));
        }
      },
    ),
    Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        tr(
          "Выбор среди уже известных версий того же трека. Если подходящей нет, скачивается выбранная версия. Файлы сохраняются без перекодирования; битрейт задаёт источник. Автокеш и предзагрузка сохраняют версию для воспроизведения.",
        ),
        style: TextStyle(color: muted, fontSize: 12),
      ),
    ),
    DropdownButtonFormField<int>(
      key: ValueKey('prefetch-tracks-${widget.app.prefetch.count}'),
      initialValue: widget.app.prefetch.count,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: tr("Загружать следующие треки заранее"),
      ),
      items: [
        for (var count = 0; count <= 10; count++)
          DropdownMenuItem(
            value: count,
            child: Text(count == 0 ? tr("Отключено") : '$count'),
          ),
      ],
      onChanged: (value) {
        if (value != null) unawaited(widget.app.prefetch.setCount(value));
      },
    ),
    Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        tr(
          "По умолчанию 3 следующих незагруженных трека из текущей очереди. Офлайн-копии пропускаются. При паузе подготовка приостанавливается; готовые файлы сохраняются.",
        ),
        style: TextStyle(color: muted, fontSize: 11),
      ),
    ),
    Text(
      tr(
        "Лайкнутые и скачанные треки не удаляются автоматически или при удалении альбома. Офлайн-копию можно удалить только вручную с подтверждением. Лимит места останавливает новые загрузки, сохраняя существующие файлы.",
      ),
      style: TextStyle(color: muted),
    ),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        tr("Скачивать прослушиваемые треки"),
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        tr("Автоматически сохранять торрент-треки для офлайн"),
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
      decoration: InputDecoration(
        labelText: tr("Одновременные загрузки треков"),
      ),
      items: [
        for (final count in [1, 2, 3, 4, 5, 6])
          DropdownMenuItem(
            value: count,
            child: Text(
              count == 1
                  ? tr("1 · по очереди")
                  : tr("{0} · параллельно", [count]),
            ),
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
    Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        tr(
          "По умолчанию 3. Прослушиваемый трек получает место в очереди первым. Пауза сохраняет загруженную часть файла.",
        ),
        style: TextStyle(color: muted, fontSize: 11),
      ),
    ),
    TextField(
      controller: limit,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: tr("Лимит офлайн-загрузок, МБ"),
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
      child: Text(tr("Сохранить лимит")),
    ),
  ];

  List<Widget> _metadataControls() => [
    SectionTitle(tr("Обложки и музыкальные метаданные")),
    Text(
      tr(
        "MusicBrainz помогает сопоставлять исполнителей и альбомы. Cover Art Archive предоставляет обложки. Данные сохраняются на диске; при заполнении кеша удаляются самые старые записи.",
      ),
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
      decoration: InputDecoration(
        labelText: tr("Лимит кеша обложек и метаданных"),
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
          DropdownMenuItem(value: mb, child: Text(tr("{0} МБ", [mb]))),
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
        tr("{0} из {1} · {2} записей", [
          formatBytes(widget.app.cacheStats!.bytes),
          formatBytes(widget.app.cacheStats!.maxBytes),
          widget.app.cacheStats!.count,
        ]),
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
          label: Text(tr("Очистить кеш")),
        ),
        TextButton(
          onPressed: widget.app.cacheBusy
              ? null
              : widget.app.refreshMetadataCache,
          child: Text(tr("Обновить размер")),
        ),
      ],
    ),
  ];

  List<Widget> _profileControls() => [
    SectionTitle(tr("Профиль на другом устройстве")),
    Text(
      tr(
        "Сохрани профиль в файл и открой его в Mumpa на другом устройстве. В файл попадут любимые треки, альбомы, плейлисты и их порядок, метаданные и источники музыки, история, статистика, выбранные версии треков, очередь и настройки плеера.",
      ),
    ),
    const SizedBox(height: 16),
    Text(
      tr(
        "Музыка и обложки в файл не входят. Торрент-треки можно скачать заново при наличии пиров. Для локальной музыки сохраняются названия и избранное; сами файлы нужно перенести отдельно. Адреса серверов, сетевой интерфейс, пароли и данные входа на новом устройстве настраиваются отдельно.",
      ),
      style: TextStyle(color: muted, fontSize: 12),
    ),
    const SizedBox(height: 20),
    Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          key: const ValueKey('export-profile'),
          onPressed: widget.app.busy == null ? widget.app.exportProfile : null,
          icon: const Icon(Icons.file_upload_outlined),
          label: Text(tr("Экспортировать профиль")),
        ),
        OutlinedButton.icon(
          key: const ValueKey('import-profile'),
          onPressed: widget.app.busy == null ? _importProfile : null,
          icon: const Icon(Icons.file_download_outlined),
          label: Text(tr("Импортировать профиль")),
        ),
      ],
    ),
    const SizedBox(height: 16),
    Text(
      tr(
        "Импорт объединяет данные с текущей медиатекой. Существующие треки, локальные файлы и порядок в плейлистах сохраняются. Перед импортом автоматически создаётся резервная копия профиля.",
      ),
      style: TextStyle(color: muted, fontSize: 12),
    ),
  ];

  Future<void> _importProfile() async {
    final transfer = await widget.app.pickProfile();
    if (transfer == null || !mounted) return;
    var includeSettings = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialogState) => AlertDialog(
          title: Text(tr("Импортировать профиль?")),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    "Треков: {0}\nЛюбимых треков: {1}\nЛюбимых альбомов: {2}\nПлейлистов и коллекций: {3}",
                    [
                      transfer.trackCount,
                      transfer.favoriteCount,
                      transfer.albumCount,
                      transfer.playlistCount,
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  tr(
                    "Данные будут добавлены к текущей медиатеке. Повторный импорт не создаёт дубликатов. Текущая очередь воспроизведения сохранится.",
                  ),
                ),
                if (transfer.localTrackCount > 0) ...[
                  const SizedBox(height: 12),
                  Text(
                    tr(
                      "Локальных треков без аудиофайлов: {0}. Для прослушивания потребуется отдельно добавить музыку.",
                      [transfer.localTrackCount],
                    ),
                  ),
                ],
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr("Перенести настройки плеера")),
                  subtitle: Text(
                    tr(
                      "Сохранённая очередь восстановится, если текущая пуста.",
                    ),
                  ),
                  value: includeSettings,
                  onChanged: (value) =>
                      setDialogState(() => includeSettings = value ?? true),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr("Отмена")),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr("Импортировать")),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      await widget.app.importProfile(
        transfer,
        includeSettings: includeSettings,
      );
    }
  }

  List<Widget> _aboutControls() => [
    AppUpdatePanel(
      updates: widget.app.updates,
      quit: () async {
        final shell = widget.app.windowsPlayer;
        if (shell == null || !shell.available) {
          throw FormatException(
            tr("Перезапуск недоступен. Заверши Mumpa и повтори установку."),
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
    Text(
      tr(
        "Музыка из твоих файлов и источников.\nДемо Mumpa Sessions — оригинальные синтезированные фрагменты.\nFlutter · media_kit · TorrServer MatriX.145.2",
      ),
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
      child: Text(tr("Лицензии компонентов")),
    ),
    const SizedBox(height: 12),
    SelectableText(
      tr("Библиотека: {0}", [widget.app.library.root.path]),
      style: const TextStyle(fontSize: 10, color: muted),
    ),
    const SizedBox(height: 8),
    Text(
      tr(
        "Избранное и настройки сохраняются отдельно от приложения. Резервные копии за последние 7 дней находятся в подпапке backups. Обновление и очистка кеша сохраняют эти данные.",
      ),
      style: TextStyle(fontSize: 11, color: muted),
    ),
    if (Platform.isAndroid)
      Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          tr("Импорт на Android сохраняет копии в приватной папке приложения."),
          style: TextStyle(color: muted, fontSize: 11),
        ),
      ),
  ];
}
