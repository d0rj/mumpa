part of 'pages.dart';

class _DownloadsPage extends StatelessWidget {
  const _DownloadsPage(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final tracks = app.offlineSearchTracks;
    final jobs = app.downloadSearchJobs;
    final searching = normalizeMusicName(
      app.localQuery('downloads'),
    ).isNotEmpty;
    return _PageBody(
      children: [
        SectionTitle(
          'С тобой без интернета',
          subtitle:
              '${app.offlineTracks.length} скачанных треков · ${formatBytes(app.offlineTracks.fold<int>(0, (a, t) => a + t.bytes))}',
        ),
        if (Platform.isWindows)
          SelectableText(
            'Папка загрузок: ${app.library.downloads.path}',
            style: const TextStyle(fontSize: 11, color: muted),
          ),
        LocalSearchField(
          app: app,
          scope: 'downloads',
          hint: 'Поиск в офлайн-музыке и загрузках',
        ),
        if (jobs.isNotEmpty) ...[
          const SectionTitle('Загрузки'),
          LazyRows(
            count: jobs.length,
            builder: (_, i) {
              final job = jobs[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    CoverArt(
                      seed: job.track.album,
                      path: job.track.artPath,
                      size: 46,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            job.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 5),
                          if (job.state == DownloadState.downloading)
                            LinearProgressIndicator(
                              value: job.progress,
                              minHeight: 3,
                              backgroundColor: const Color(0xFF303831),
                            ),
                          const SizedBox(height: 5),
                          Text(
                            job.error ??
                                switch (job.state) {
                                  DownloadState.queued => 'В очереди',
                                  DownloadState.downloading =>
                                    '${formatBytes(job.received)} / ${formatBytes(job.total)}',
                                  DownloadState.paused =>
                                    'Приостановлено · ${formatBytes(job.received)}',
                                  DownloadState.complete => 'Готово для офлайн',
                                  DownloadState.failed => 'Ошибка загрузки',
                                },
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: job.state == DownloadState.failed
                                  ? const Color(0xFFFF9292)
                                  : muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (job.state == DownloadState.downloading ||
                        job.state == DownloadState.queued)
                      IconButton(
                        onPressed: () => app.downloads.pause(job.track.id),
                        tooltip: 'Приостановить',
                        icon: const Icon(Icons.pause_rounded),
                      )
                    else if (job.state == DownloadState.paused ||
                        job.state == DownloadState.failed)
                      IconButton(
                        onPressed: () => app.downloads.retry(job.track.id),
                        tooltip: 'Продолжить',
                        icon: const Icon(
                          Icons.play_arrow_rounded,
                          color: accent,
                        ),
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Icon(Icons.check_circle_rounded, color: accent),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
        if (tracks.isNotEmpty) ...[
          const SectionTitle('Скачанные треки'),
          TrackList(app: app, tracks: tracks),
        ] else if (searching && jobs.isEmpty)
          const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Ничего не найдено в этом разделе',
            description: 'Попробуй другой запрос или очисти поиск.',
          )
        else if (!searching && jobs.isEmpty)
          const EmptyState(
            icon: Icons.offline_bolt_rounded,
            title: 'Сохрани музыку для дороги',
            description:
                'Открой торрент-альбом и нажми «Скачать альбом». Завершённые загрузки играют без сети.',
          ),
      ],
    );
  }
}
