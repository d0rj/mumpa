import 'dart:io';
import 'package:flutter/material.dart';
import '../data/rutracker_service.dart';
import '../domain/models.dart';
import '../logic/app_controller.dart';
import 'components.dart';
import 'dialogs.dart';
import 'jackett_setup.dart';
import 'theme.dart';

class SearchProviderPicker extends StatelessWidget {
  const SearchProviderPicker({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      ChoiceChip(
        label: const Text('Jackett'),
        selected: app.usesIndexer,
        onSelected: (_) => app.setSearchProvider('torznab'),
      ),
      ChoiceChip(
        label: const Text('RuTracker напрямую'),
        selected: !app.usesIndexer,
        onSelected: (_) => app.setSearchProvider('rutracker'),
      ),
    ],
  );
}

List<Widget> sourceContent(BuildContext context, AppController app) => [
  SectionTitle(
    'Музыка через Jackett',
    subtitle: 'RuTracker и другие подключённые музыкальные трекеры',
    action: IconButton(
      onPressed: app.indexerLoading ? null : app.refreshSourceFeed,
      icon: const Icon(Icons.refresh_rounded),
      tooltip: 'Обновить раздачи',
    ),
  ),
  if (app.indexerLoading) const LinearProgressIndicator(minHeight: 2),
  if (!app.indexerConnected)
    EmptyState(
      icon: Icons.travel_explore_rounded,
      title: 'Подключи музыкальный каталог',
      description: Platform.isWindows
          ? 'Запусти Jackett, добавь RuTracker.org и укажи свой аккаунт. После этого здесь появятся реальные музыкальные раздачи.'
          : 'Подключи Jackett с RuTracker на ПК или сервере: укажи его адрес и API key в настройках.',
      action: FilledButton.icon(
        onPressed: app.busy == null ? () => setupJackett(context, app) : null,
        icon: const Icon(Icons.settings_rounded, size: 18),
        label: Text(
          Platform.isWindows
              ? 'Настроить Jackett и RuTracker'
              : 'Подключить Jackett',
        ),
      ),
    )
  else ...[
    if (app.indexerError != null)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              app.indexerError!,
              style: const TextStyle(color: Color(0xFFFF9292)),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: app.busy == null
                  ? () => setupJackett(context, app)
                  : null,
              child: const Text('Настроить трекеры'),
            ),
          ],
        ),
      ),
    if (app.sourceFeed.isNotEmpty)
      ReleaseRows(app: app, releases: app.sourceFeed)
    else if (!app.indexerLoading && app.indexerError == null)
      EmptyState(
        icon: Icons.album_outlined,
        title: 'Музыкальных раздач пока нет',
        description:
            'Убедись, что RuTracker.org добавлен и проверка трекера в Jackett проходит. Можно также поискать исполнителя по имени.',
        action: TextButton(
          onPressed: () => setupJackett(context, app),
          child: const Text('Настроить трекеры'),
        ),
      ),
  ],
];

List<Widget> catalogContent(
  BuildContext context,
  AppController app, {
  bool home = false,
}) {
  final sections = home ? app.catalog.sections : app.catalogSections;
  return [
    SectionTitle(
      home
          ? 'Открой новую музыку'
          : app.catalogTrail.lastOrNull?.title ?? 'Жанры RuTracker',
      subtitle: home
          ? 'Каталог RuTracker · выбери жанр или найди исполнителя'
          : 'Музыкальные раздачи RuTracker',
      action: IconButton(
        onPressed: app.catalogLoading ? null : app.refreshCatalog,
        icon: const Icon(Icons.refresh_rounded),
        tooltip: 'Обновить каталог',
      ),
    ),
    if (!home && app.catalogTrail.isNotEmpty)
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: app.catalogBack,
          icon: const Icon(Icons.arrow_back_rounded, size: 17),
          label: const Text('Назад к жанрам'),
        ),
      ),
    if (app.catalogLoading)
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(minHeight: 2),
      ),
    if (app.catalogError != null) CatalogNotice(app: app),
    if (sections.isNotEmpty) _SectionGrid(app, sections),
    if (!home && app.catalogReleases.isNotEmpty) ...[
      SectionTitle(
        'Альбомы и дискографии',
        subtitle: '${app.catalogReleases.length} раздач',
      ),
      ReleaseRows(app: app, releases: app.catalogReleases),
      if (app.catalogNextPath != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: OutlinedButton(
            onPressed: app.catalogLoading ? null : app.loadMoreCatalog,
            child: const Text('Показать ещё'),
          ),
        ),
    ],
    if (!app.catalogLoading &&
        app.catalogError == null &&
        sections.isEmpty &&
        (home || app.catalogReleases.isEmpty))
      EmptyState(
        icon: Icons.explore_outlined,
        title: 'Загрузи каталог музыки',
        description:
            'В Mumpa доступны музыкальные разделы RuTracker. Поиск по всему каталогу требует аккаунт RuTracker.',
        action: FilledButton(
          onPressed: app.refreshCatalog,
          child: const Text('Загрузить каталог'),
        ),
      ),
  ];
}

class CatalogNotice extends StatelessWidget {
  const CatalogNotice({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF272D23),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          app.catalogError ?? '',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (app.catalogNeedsConnection)
              FilledButton.icon(
                onPressed: app.busy == null
                    ? () => app.connectCatalog(login: app.catalogNeedsLogin)
                    : null,
                icon: const Icon(Icons.login_rounded, size: 18),
                label: Text(
                  app.catalogNeedsLogin
                      ? 'Войти в RuTracker'
                      : 'Открыть RuTracker',
                ),
              ),
            TextButton(
              onPressed: app.catalogLoading || app.searching
                  ? null
                  : () => app.query.trim().isNotEmpty
                        ? app.searchSources()
                        : app.refreshCatalog(),
              child: const Text('Повторить'),
            ),
          ],
        ),
      ],
    ),
  );
}

class _SectionGrid extends SliverContent {
  const _SectionGrid(this.app, this.sections);
  final AppController app;
  final List<CatalogSection> sections;
  static const colors = [
    Color(0xFF34533B),
    Color(0xFF604339),
    Color(0xFF343E63),
    Color(0xFF66334E),
    Color(0xFF315C60),
    Color(0xFF575232),
  ];
  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (_, constraints) => SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: (constraints.crossAxisExtent / 240).floor().clamp(1, 4),
        mainAxisExtent: 112,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: sections.length,
      itemBuilder: (_, i) {
        final section = sections[i];
        return Material(
          color: colors[i % colors.length],
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => app.browseCatalog(section),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      section.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white54,
                    size: 22,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

class ReleaseRows extends SliverContent {
  const ReleaseRows({super.key, required this.app, required this.releases});
  final AppController app;
  final List<SearchRelease> releases;
  @override
  Widget build(BuildContext context) => LazyRows(
    count: releases.length,
    builder: (context, i) {
      final item = releases[i];
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        leading: CoverArt(seed: item.title, size: 48),
        title: Text(
          item.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${item.bytes > 0 ? '${formatBytes(item.bytes)} · ' : ''}${item.seeders} сидов${item.category.isNotEmpty ? ' · ${item.category}' : ''}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: muted, fontSize: 11),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: app.busy != null
            ? null
            : () async {
                final result = await app.inspectRelease(item);
                if (result != null && context.mounted) {
                  await selectTorrent(
                    context,
                    app,
                    result.info,
                    link: result.link,
                  );
                }
              },
      );
    },
  );
}
