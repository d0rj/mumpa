import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../logic/app_controller.dart';
import 'components.dart';
import 'dialogs.dart';
import 'pages.dart';
import 'player.dart';
import 'theme.dart';

class MumpaApp extends StatelessWidget {
  const MumpaApp({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Mumpa',
    debugShowCheckedModeBanner: false,
    theme: mumpaTheme(),
    home: AppScreen(app: controller),
  );
}

class AppScreen extends StatelessWidget {
  const AppScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => Focus(
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (HardwareKeyboard.instance.isControlPressed &&
          event.logicalKey == LogicalKeyboardKey.keyK) {
        app.navigate(AppPage.search);
        return KeyEventResult.handled;
      }
      final editing =
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorStateOfType<EditableTextState>() !=
          null;
      if (!editing && event.logicalKey == LogicalKeyboardKey.space) {
        app.playback.toggle();
        return KeyEventResult.handled;
      }
      if (HardwareKeyboard.instance.isAltPressed &&
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        app.playback.next();
        return KeyEventResult.handled;
      }
      if (HardwareKeyboard.instance.isAltPressed &&
          event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        app.playback.previous();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: ListenableBuilder(
      listenable: app,
      builder: (context, _) => LayoutBuilder(
        builder: (context, c) {
          final desktop = c.maxWidth >= 850;
          return Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (desktop) SizedBox(width: 236, child: _Sidebar(app)),
                        Expanded(
                          child: Container(
                            margin: desktop
                                ? const EdgeInsets.fromLTRB(0, 8, 8, 8)
                                : EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: surface,
                              borderRadius: BorderRadius.circular(
                                desktop ? 12 : 0,
                              ),
                            ),
                            child: Material(
                              type: MaterialType.transparency,
                              child: Column(
                                children: [
                                  _TopBar(app, desktop),
                                  if (app.busy != null)
                                    const LinearProgressIndicator(minHeight: 2),
                                  if (app.busy != null ||
                                      app.error != null ||
                                      app.message != null ||
                                      app.playback.connectionStatus != null ||
                                      app.library.loadWarning != null)
                                    _StatusBar(app),
                                  Expanded(
                                    child: ContentPage(
                                      key: ValueKey(app.page),
                                      app: app,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  PlayerBar(app: app, compact: !desktop),
                  if (!desktop)
                    NavigationBar(
                      selectedIndex: switch (app.page) {
                        AppPage.search => 1,
                        AppPage.library ||
                        AppPage.album ||
                        AppPage.playlist ||
                        AppPage.artist => 2,
                        AppPage.liked => 3,
                        AppPage.downloads || AppPage.settings => 4,
                        _ => 0,
                      },
                      onDestinationSelected: (index) => app.navigate(
                        [
                          AppPage.home,
                          AppPage.search,
                          AppPage.library,
                          AppPage.liked,
                          AppPage.downloads,
                        ][index],
                      ),
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.home_outlined),
                          selectedIcon: Icon(Icons.home_rounded),
                          label: 'Главная',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.search_rounded),
                          label: 'Поиск',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.library_music_outlined),
                          selectedIcon: Icon(Icons.library_music_rounded),
                          label: 'Медиатека',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.favorite_border_rounded),
                          selectedIcon: Icon(Icons.favorite_rounded),
                          label: 'Любимое',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.download_outlined),
                          selectedIcon: Icon(Icons.download_rounded),
                          label: 'Офлайн',
                        ),
                      ],
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 22, 14, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 12, bottom: 28),
          child: Row(
            children: [
              Icon(Icons.graphic_eq_rounded, color: accent, size: 30),
              SizedBox(width: 8),
              Text(
                'mumpa',
                style: TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.5,
                ),
              ),
            ],
          ),
        ),
        _NavItem(app, 'Главная', Icons.home_outlined, AppPage.home),
        _NavItem(app, 'Поиск', Icons.search_rounded, AppPage.search),
        const SizedBox(height: 24),
        const Padding(
          padding: EdgeInsets.only(left: 14, bottom: 10),
          child: Text(
            'ТВОЯ КОЛЛЕКЦИЯ',
            style: TextStyle(
              color: muted,
              fontSize: 9,
              letterSpacing: 1.8,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        _NavItem(
          app,
          'Медиатека',
          Icons.library_music_outlined,
          AppPage.library,
        ),
        _NavItem(
          app,
          'Любимые треки',
          Icons.favorite_border_rounded,
          AppPage.liked,
        ),
        _NavItem(app, 'Офлайн', Icons.download_outlined, AppPage.downloads),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Text(
                'ПЛЕЙЛИСТЫ',
                style: TextStyle(
                  color: muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.8,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () async {
                  final name = await askName(context, 'Новый плейлист');
                  if (name != null) {
                    app.openPlaylist(await app.library.createPlaylist(name));
                  }
                },
                tooltip: 'Новый плейлист',
                icon: const Icon(Icons.add_rounded, size: 18, color: muted),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: app.library.playlists.length,
            itemBuilder: (_, i) {
              final playlist = app.library.playlists[i];
              return ListTile(
                dense: true,
                onTap: () => app.openPlaylist(playlist),
                leading: CoverArt(seed: playlist.name, size: 32, radius: 4),
                title: Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  '${playlist.trackIds.length} треков',
                  style: const TextStyle(fontSize: 9, color: muted),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              );
            },
          ),
        ),
        OutlinedButton.icon(
          onPressed: app.busy == null ? () => showAddMusic(context, app) : null,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Добавить музыку', style: TextStyle(fontSize: 11)),
        ),
        const SizedBox(height: 12),
        _NavItem(app, 'Настройки', Icons.tune_rounded, AppPage.settings),
        const Padding(
          padding: EdgeInsets.only(left: 14, top: 10),
          child: Text(
            'ТВОИ ФАЙЛЫ. ТВОЙ РИТМ.',
            style: TextStyle(
              fontSize: 8,
              color: Color(0xFF616C60),
              letterSpacing: 1.6,
            ),
          ),
        ),
      ],
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem(this.app, this.label, this.icon, this.page);
  final AppController app;
  final String label;
  final IconData icon;
  final AppPage page;
  @override
  Widget build(BuildContext context) {
    final selected = app.page == page;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? const Color(0xFF293625) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => app.navigate(page),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: selected ? accent : muted),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : muted,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar(this.app, this.desktop);
  final AppController app;
  final bool desktop;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(desktop ? 26 : 10, 12, desktop ? 26 : 10, 8),
    child: Row(
      children: [
        IconButton(
          onPressed: app.back,
          tooltip: 'Назад',
          icon: const Icon(Icons.chevron_left_rounded, size: 26),
        ),
        if (desktop) const SizedBox(width: 16),
        Expanded(
          child: desktop
              ? InkWell(
                  onTap: () => app.navigate(AppPage.search),
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 430),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF242A25),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.search_rounded, size: 19, color: muted),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Треки, альбомы, исполнители',
                            style: TextStyle(fontSize: 11, color: muted),
                          ),
                        ),
                        Text(
                          'Ctrl K',
                          style: TextStyle(fontSize: 9, color: muted),
                        ),
                      ],
                    ),
                  ),
                )
              : const Row(
                  children: [
                    Icon(Icons.graphic_eq_rounded, size: 21, color: accent),
                    SizedBox(width: 6),
                    Text(
                      'mumpa',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(width: 16),
        IconButton(
          onPressed: app.busy == null ? () => showAddMusic(context, app) : null,
          tooltip: 'Добавить музыку',
          icon: const Icon(Icons.add_circle_outline_rounded, size: 22),
        ),
        if (!desktop)
          IconButton(
            onPressed: () => app.navigate(AppPage.settings),
            tooltip: 'Настройки',
            icon: const Icon(Icons.tune_rounded, size: 21),
          ),
        if (desktop)
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFF35462A),
              shape: BoxShape.circle,
            ),
            child: const Text(
              'M',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: accent,
              ),
            ),
          ),
      ],
    ),
  );
}

class _StatusBar extends StatelessWidget {
  const _StatusBar(this.app);
  final AppController app;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    color: app.error != null
        ? const Color(0xFF442A2A)
        : const Color(0xFF263024),
    child: Row(
      children: [
        Icon(
          app.error != null
              ? Icons.error_outline_rounded
              : Icons.info_outline_rounded,
          size: 17,
          color: app.error != null ? const Color(0xFFFF9292) : accent,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            app.error ??
                app.busy ??
                app.playback.connectionStatus ??
                app.message ??
                app.library.loadWarning ??
                '',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ),
        if (app.canCancelOpening)
          TextButton(
            key: const Key('cancel-opening'),
            onPressed: app.cancelOpening,
            child: const Text('Отмена'),
          ),
        if (app.playback.connectionStatus != null)
          TextButton(
            key: const Key('cancel-playback'),
            onPressed: app.playback.stop,
            child: const Text('Отмена'),
          ),
        if (app.playback.error != null && app.error == app.playback.error)
          TextButton(
            key: const Key('retry-playback'),
            onPressed: app.playback.play,
            child: const Text('Повторить'),
          ),
        if (app.busy == null)
          IconButton(
            onPressed: () {
              app.library.loadWarning = null;
              app.clearMessage();
            },
            tooltip: 'Закрыть уведомление',
            icon: const Icon(Icons.close_rounded, size: 17),
            visualDensity: VisualDensity.compact,
          ),
      ],
    ),
  );
}
