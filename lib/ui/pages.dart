import '../l10n/app_localizations.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../data/download_repository.dart';
import '../data/library_repository.dart';
import '../domain/models.dart';
import '../domain/music_metadata.dart';
import '../domain/collection_filter.dart';
import '../data/rutracker_service.dart';
import 'catalog_widgets.dart';
import 'jackett_setup.dart';
import '../logic/app_controller.dart';
import 'components.dart';
import 'dialogs.dart';
import 'theme.dart';
import 'search_fields.dart';
import 'app_update_panel.dart';
import 'audio_settings.dart';
import 'local_tools.dart';
import 'lan_transfer_view.dart';

part 'library_pages.dart';
part 'artist_page.dart';
part 'collection_pages.dart';
part 'search_page.dart';
part 'downloads_page.dart';
part 'settings_page.dart';

class ContentPage extends StatelessWidget {
  const ContentPage({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => switch (app.page) {
    AppPage.home => _HomePage(app),
    AppPage.library => _LibraryPage(app),
    AppPage.search => _SearchPage(app),
    AppPage.liked => _LikedPage(app),
    AppPage.downloads => _DownloadsPage(app),
    AppPage.settings => SettingsPage(key: const ValueKey('settings'), app: app),
    AppPage.album =>
      app.album == null
          ? EmptyState(
              icon: Icons.album_outlined,
              title: tr("Альбом удалён"),
              description: tr("Открой другой альбом в медиатеке."),
            )
          : _AlbumPage(app, app.album!),
    AppPage.playlist => _TrackCollection(
      app: app,
      title: app.playlist?.name ?? tr("Плейлист"),
      eyebrow: app.playlist?.isSystem == true
          ? tr("НА ЭТОМ УСТРОЙСТВЕ")
          : app.playlist?.sourceHash != null
          ? tr("КОЛЛЕКЦИЯ")
          : tr("ПЛЕЙЛИСТ"),
      tracks: app.playlistTracks,
      icon: Icons.queue_music_rounded,
      playlistId: app.playlist?.id,
    ),
    AppPage.artist => _ArtistPage(app),
  };
}

class _PageBody extends StatelessWidget {
  const _PageBody({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, c) => CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            c.maxWidth > 700 ? 32 : 18,
            12,
            c.maxWidth > 700 ? 32 : 18,
            36,
          ),
          sliver: SliverMainAxisGroup(
            slivers: children
                .map(
                  (child) => child is SliverContent
                      ? child
                      : SliverToBoxAdapter(child: child),
                )
                .toList(),
          ),
        ),
      ],
    ),
  );
}

Widget albumGrid(AppController app, List<Album> albums, {int? limit}) =>
    _AlbumGrid(app, limit == null ? albums : albums.take(limit).toList());

class _AlbumGrid extends SliverContent {
  const _AlbumGrid(this.app, this.items, {this.playlistId});
  final AppController app;
  final List<Album> items;
  final String? playlistId;
  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (_, c) => SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: (c.crossAxisExtent / 190).floor().clamp(2, 8),
        childAspectRatio: .76,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => AlbumCard(
        app: app,
        album: items[i],
        onOpen: () => app.openAlbum(items[i], playlistId: playlistId),
        onPlay: () =>
            app.playCollection(items[i].tracks, playlistId: playlistId),
        onArtist: () => app.openArtist(items[i].artist),
      ),
    ),
  );
}
