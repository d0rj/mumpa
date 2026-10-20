part of 'pages.dart';

class _SearchPage extends StatelessWidget {
  const _SearchPage(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) => _PageBody(
    children: [
      SectionTitle(
        tr("Найди свой звук"),
        subtitle: app.usesAutomaticSource
            ? tr("Твоя медиатека и готовый музыкальный каталог")
            : app.usesIndexer
            ? tr("Твоя медиатека и музыкальные трекеры Jackett")
            : tr("Твоя медиатека и музыкальный каталог RuTracker"),
      ),
      SearchOptionsPanel(app: app),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: app.searching ? null : app.searchSources,
            icon: app.searching
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.search_rounded, size: 18),
            label: Text(
              app.trackSearchMode
                  ? tr("Искать треки")
                  : app.usesAutomaticSource
                  ? tr("Искать музыку")
                  : app.usesIndexer
                  ? tr("Искать через Jackett")
                  : tr("Искать на RuTracker"),
            ),
          ),
          if (!app.usesIndexer && app.catalog.username == null)
            TextButton(
              onPressed: () => app.connectCatalog(),
              child: Text(tr("Войти в RuTracker")),
            ),
        ],
      ),
      if (app.trackSearchMode && app.selectedRecording != null) ...[
        SectionTitle(
          tr("Версии «{0}»", [app.selectedRecording!.title]),
          subtitle: app.selectedRecording!.artist,
          action: app.versionLoading
              ? TextButton(
                  onPressed: app.cancelVersionSearch,
                  child: Text(tr("Отменить")),
                )
              : null,
        ),
        if (app.versionLoading) const LinearProgressIndicator(minHeight: 2),
        if (app.versionStatus != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.versionStatus!,
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ),
        if (app.versionError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.versionError!,
              style: const TextStyle(color: Color(0xFFFF9292), fontSize: 12),
            ),
          ),
        if (app.trackVariants.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              tr(
                "Выбери формат и раздачу. Метки Clean и «без цензуры» взяты из описания версии.",
              ),
              style: TextStyle(color: muted, fontSize: 11),
            ),
          ),
          TrackVariantRows(app: app),
        ],
      ],
      if (app.query.trim().isEmpty && !app.trackSearchMode)
        ...(app.usesIndexer
            ? sourceContent(context, app)
            : catalogContent(context, app))
      else if (app.trackSearchMode) ...[
        if (app.metadataError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.metadataError!,
              style: const TextStyle(color: Color(0xFFFF9292), fontSize: 12),
            ),
          ),
        SectionTitle(
          tr("Треки в MusicBrainz"),
          subtitle: app.searching
              ? tr("Ищем…")
              : app.recordingResults.isNotEmpty
              ? tr("Найдено: {0}", [app.recordingResults.length])
              : tr("Введи название трека и исполнителя"),
        ),
        if (app.recordingResults.isNotEmpty)
          RecordingRows(app: app, recordings: app.recordingResults)
        else if (!app.searching &&
            app.searchCompleted &&
            app.metadataError == null)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              tr(
                "Треки не найдены. Попробуй добавить имя исполнителя или поискать альбом в источниках.",
              ),
              style: TextStyle(color: muted),
            ),
          ),
      ] else ...[
        if (app.indexerNotice != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.indexerNotice!,
              style: const TextStyle(color: muted),
            ),
          ),
        if (!app.usesIndexer && app.catalogError != null)
          CatalogNotice(app: app),
      ],
      if (app.query.trim().isNotEmpty && !app.trackSearchMode) ...[
        if (app.searchCorrectionCandidate != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              tr("По исходному запросу ничего не найдено. Проверяем «{0}»…", [
                app.searchCorrectionCandidate,
              ]),
              style: const TextStyle(color: muted),
            ),
          )
        else if (app.correctedSearchQuery != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.releases.isNotEmpty
                  ? tr(
                      "По запросу «{0}» ничего не найдено. Показаны результаты для «{1}».",
                      [app.query.trim(), app.correctedSearchQuery],
                    )
                  : tr("Также проверили «{0}»: раздачи не найдены.", [
                      app.correctedSearchQuery,
                    ]),
              style: const TextStyle(color: muted),
            ),
          ),
        if (app.searchCorrectionSuggestions.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              tr("Есть несколько похожих названий. Уточни запрос:"),
              style: TextStyle(color: muted),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final suggestion in app.searchCorrectionSuggestions)
                ActionChip(
                  label: Text(suggestion),
                  onPressed: () {
                    app.setQuery(suggestion);
                    app.searchSources();
                  },
                ),
            ],
          ),
        ],
        SectionTitle(
          app.usesAutomaticSource
              ? tr("В музыкальном каталоге")
              : app.usesIndexer
              ? tr("В трекерах Jackett")
              : tr("На RuTracker"),
          subtitle: app.searching
              ? tr("Ищем…")
              : app.searchCompleted
              ? tr("Найдено: {0}", [app.releases.length])
              : tr("Начни вводить запрос"),
        ),
        if (app.releases.isNotEmpty)
          ReleaseRows(app: app, releases: app.releases)
        else if (!app.searching && app.catalogError == null)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              app.searchCompleted
                  ? tr(
                      "В подключённых источниках ничего не найдено. Проверь название или подключи другой музыкальный трекер.",
                    )
                  : tr("Нажми «Искать», чтобы найти альбомы в каталоге."),
              style: const TextStyle(color: muted),
            ),
          ),
      ],
      if (app.query.trim().isNotEmpty) ...[
        SectionTitle(
          tr("В твоей медиатеке"),
          subtitle: tr("Найдено: {0}", [
            app.library.matchedTracks(app.searchTracks).length,
          ]),
        ),
        if (app.searchTracks.isNotEmpty)
          TrackList(app: app, tracks: app.searchTracks)
        else
          Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text(
              tr("В локальной медиатеке пока ничего не найдено."),
              style: TextStyle(color: muted),
            ),
          ),
      ],
    ],
  );
}
