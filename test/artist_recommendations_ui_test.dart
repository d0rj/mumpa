import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mumpa/data/download_repository.dart';
import 'package:mumpa/data/library_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/data/similar_artists_repository.dart';
import 'package:mumpa/data/source_operation.dart';
import 'package:mumpa/data/torrent_service.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';
import 'package:mumpa/domain/similar_artist.dart';
import 'package:mumpa/logic/app_controller.dart';
import 'package:mumpa/logic/playback_controller.dart';
import 'package:mumpa/ui/components.dart';
import 'package:mumpa/ui/pages.dart';
import 'package:mumpa/ui/theme.dart';

import 'support.dart';

const _a = '11111111-1111-4111-8111-111111111111';
const _b = '22222222-2222-4222-8222-222222222222';
const _c = '33333333-3333-4333-8333-333333333333';
const _artistA = 'Моя группа';
const _artistB = 'Группа из каталога';
const _recommendedB = SimilarArtist(
  id: _b,
  name: 'Имя с неоднозначным совпадением',
  score: 30,
);
const _recommendedC = SimilarArtist(id: _c, name: 'Другой похожий', score: 12);

class _Metadata extends MusicMetadataRepository {
  _Metadata(Directory root)
    : super(
        cache: DiskMediaCache(Directory('${root.path}/metadata')),
        client: MockClient((_) async => throw StateError('Unexpected network')),
      );

  final namedRequests = <String>[];
  final idRequests = <String>[];

  @override
  Future<MusicArtist?> artist(String name, {SourceOperation? operation}) async {
    namedRequests.add(name);
    return MusicArtist(id: name == _artistA ? _a : _b, name: name);
  }

  @override
  Future<MusicArtist> artistById(
    String id, {
    SourceOperation? operation,
  }) async {
    idRequests.add(id);
    return MusicArtist(id: id, name: _artistB);
  }

  @override
  Future<String?> cachedCoverForAlbum(String artist, String album) async =>
      null;
  @override
  Future<String?> coverForAlbum(String artist, String album) async => null;
}

class _PendingRecommendations {
  _PendingRecommendations(this.id, this.operation);
  final String id;
  final SourceOperation? operation;
  final result = Completer<List<SimilarArtist>>();
}

class _Recommendations extends SimilarArtistsRepository {
  _Recommendations(_Metadata metadata)
    : super(cache: metadata.cache, client: metadata.client);

  final requests = <_PendingRecommendations>[];

  @override
  Future<List<SimilarArtist>> similarArtists(
    String artistId, {
    SourceOperation? operation,
  }) {
    final request = _PendingRecommendations(artistId, operation);
    requests.add(request);
    // Deliberately finish even cancelled calls: AppController must reject
    // obsolete results independently of a cooperating HTTP transport.
    return request.result.future;
  }

  @override
  void dispose() {
    for (final request in requests) {
      if (!request.result.isCompleted) request.result.complete(const []);
    }
    super.dispose();
  }
}

class _Fixture {
  _Fixture(this.root, this.app, this.metadata, this.recommendations);
  final Directory root;
  final AppController app;
  final _Metadata metadata;
  final _Recommendations recommendations;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('mumpa-artist-reco-ui-');
    final library = LibraryRepository(root);
    await library.load();
    await library.upsert(const [
      Track(
        id: 'liked',
        title: 'Любимая песня',
        artist: _artistA,
        album: 'Мой альбом',
        source: TrackSource.local,
      ),
    ]);
    await library.toggleLike('liked');
    final torrents = TorrentService(endpoint: () async => 'http://localhost');
    final playback = PlaybackController(
      library: library,
      torrents: torrents,
      backend: FakeAudioBackend(),
    );
    await playback.initialize(platformAudio: false);
    final metadata = _Metadata(root);
    final recommendations = _Recommendations(metadata);
    final app = AppController(
      library: library,
      playback: playback,
      downloads: DownloadRepository(library, torrents),
      torrents: torrents,
      engine: TorrentEngine(root),
      metadata: metadata,
      similarArtists: recommendations,
    );
    return _Fixture(root, app, metadata, recommendations);
  }
}

Finder _recommendation(String id) => find.byKey(ValueKey('similar-artist-$id'));
Finder _scroll() => find.byType(Scrollable).first;

Future<void> _show(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 150, scrollable: _scroll());
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, _Fixture fixture, String name) async {
  fixture.app.openArtist(name);
  await tester.pumpAndSettle();
}

Future<_Fixture> _mount(WidgetTester tester) async {
  final fixture = (await tester.runAsync(_Fixture.create))!;
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await fixture.app.shutdown();
      fixture.app.library.dispose();
      await fixture.root.delete(recursive: true);
    });
  });
  fixture.app.openArtist(_artistA);
  await tester.pumpWidget(
    MaterialApp(
      theme: mumpaTheme(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: fixture.app,
          builder: (_, _) => ContentPage(app: fixture.app),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  testWidgets(
    'slow recommendations leave liked songs usable and open by MBID',
    (tester) async {
      final fixture = await _mount(tester);
      final app = fixture.app;
      expect(app.artistLoading, isFalse);
      expect(app.artistProfile!.id, _a);
      expect(app.similarArtistsLoading, isTrue);
      final liked = tester.widget<TrackList>(
        find.byKey(const ValueKey('artist-liked-tracks')),
      );
      expect(liked.tracks.single.id, 'liked');
      expect(
        find.byKey(const ValueKey('similar-artists-section')),
        findsNothing,
      );
      expect(fixture.recommendations.requests.single.id, _a);

      fixture.recommendations.requests.single.result.complete([_recommendedB]);
      await tester.pumpAndSettle();
      await _show(tester, _recommendation(_b));
      await tester.tap(_recommendation(_b));
      await tester.pumpAndSettle();
      expect(fixture.metadata.idRequests, [_b]);
      expect(fixture.metadata.namedRequests, [_artistA]);
      expect(app.artistProfile!.id, _b);
      expect(app.artistProfile!.name, _artistB);
      expect(app.similarArtistResults, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late artist A recommendations cannot leak onto artist B', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final oldRequest = fixture.recommendations.requests.single;
    await _open(tester, fixture, _artistB);
    expect(oldRequest.operation!.cancelled, isTrue);
    final currentRequest = fixture.recommendations.requests.last;
    expect(currentRequest.id, _b);
    currentRequest.result.complete([_recommendedC]);
    await tester.pumpAndSettle();
    oldRequest.result.complete([_recommendedB]);
    await tester.pumpAndSettle();
    expect(fixture.app.artistProfile!.id, _b);
    expect(fixture.app.similarArtistResults.map((artist) => artist.id), [_c]);
    await _show(tester, _recommendation(_c));
    expect(_recommendation(_b), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Back restores artist recommendations and rejects outgoing work',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.recommendations.requests.single.result.complete([_recommendedB]);
      await tester.pumpAndSettle();
      await _open(tester, fixture, _artistB);
      final pendingB = fixture.recommendations.requests.last;
      fixture.app.back();
      await tester.pumpAndSettle();
      expect(pendingB.operation!.cancelled, isTrue);
      expect(fixture.app.selectedArtist, _artistA);
      expect(fixture.app.artistProfile!.id, _a);
      expect(fixture.app.similarArtistResults.map((artist) => artist.id), [_b]);
      pendingB.result.complete([_recommendedC]);
      await tester.pumpAndSettle();
      expect(fixture.app.similarArtistResults.map((artist) => artist.id), [_b]);
      await _show(tester, _recommendation(_b));
      expect(_recommendation(_c), findsNothing);
      expect(fixture.recommendations.requests.length, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty and failed optional recommendations hide the section', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    fixture.recommendations.requests.single.result.complete(const []);
    await tester.pumpAndSettle();
    await _show(tester, find.text('Об исполнителе'));
    expect(fixture.app.similarArtistResults, isEmpty);
    expect(fixture.app.similarArtistsLoading, isFalse);
    expect(find.byKey(const ValueKey('similar-artists-section')), findsNothing);
    expect(fixture.app.artistTracks.single.id, 'liked');

    await _open(tester, fixture, _artistB);
    fixture.recommendations.requests.last.result.completeError(
      const HttpException('Unavailable recommendation service'),
    );
    await tester.pumpAndSettle();
    await _show(tester, find.text('Об исполнителе'));
    expect(fixture.app.artistProfile!.id, _b);
    expect(fixture.app.similarArtistResults, isEmpty);
    expect(fixture.app.similarArtistsLoading, isFalse);
    expect(fixture.app.artistError, isNull);
    expect(find.byKey(const ValueKey('similar-artists-section')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
