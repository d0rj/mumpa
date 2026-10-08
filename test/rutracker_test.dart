import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/rutracker_service.dart';
import 'package:mumpa/domain/models.dart';

const index =
    '''<div class="category"><h3 class="cat_title"><a href="index.php?c=22">Рок-музыка</a></h3>
<h4 class="forumlink"><a href="viewforum.php?f=1698">Зарубежный Rock</a></h4>
<span class="sf_title"><a href="viewforum.php?f=1660">Rock (lossless)</a></span>
<h4 class="forumlink"><a href="viewforum.php?f=757">Предложения по улучшению</a></h4></div>
<div class="category"><h3 class="cat_title"><a href="index.php?c=2">Кино</a></h3><h4 class="forumlink"><a href="viewforum.php?f=22">Фильмы</a></h4></div>''';
const tracker =
    '''<span id="logged-in-username">Listener</span><table id="tor-tbl"><tbody><tr>
<td></td><td class="f-name-col"><div class="f-name"><a href="viewforum.php?f=1660">Rock (lossless)</a></div></td>
<td class="t-title-col"><div class="t-title"><a class="tLink" href="viewtopic.php?t=42">Artist - Album [FLAC]</a></div></td>
<td></td><td></td><td class="tor-size" data-ts_text="123456789"><a class="tr-dl" href="dl.php?t=42">117.7 MB</a></td><td><b>123</b></td>
</tr></tbody></table><div class="nav"><a href="tracker.php?nm=Artist&amp;start=50">2</a><a href="tracker.php?nm=Artist&amp;start=100">3</a></div>''';

class FixtureTransport implements CatalogTransport {
  FixtureTransport(this.respond);
  final String Function(Uri) respond;
  final List<Uri> requests = [];
  @override
  Future<String> load(Uri uri) async {
    requests.add(uri);
    return respond(uri);
  }

  @override
  Future<void> connect(Uri uri) async {}
  @override
  Future<void> logout(Uri origin) async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  test(
    'catalog contains music forums, filters help and unrelated categories',
    () {
      final sections = RuTrackerService.parseIndex(index);
      expect(sections.single.title, 'Рок-музыка');
      expect(sections.single.children.map((s) => s.path), [
        'viewforum.php?f=1698',
        'viewforum.php?f=1660',
      ]);
    },
  );
  test('tracker parses source title, true bytes, seeders and next page', () {
    final listing = RuTrackerService.parseListing(
      tracker,
      Uri.parse('https://rutracker.org/forum/tracker.php?nm=Artist'),
    );
    expect(listing.releases.single.title, 'Artist - Album [FLAC]');
    expect(listing.releases.single.bytes, 123456789);
    expect(listing.releases.single.seeders, 123);
    expect(listing.releases.single.rutracker, isTrue);
    expect(listing.nextPath, 'tracker.php?nm=Artist&start=50');
  });
  test('guest forum topics parse without tracker authorization', () {
    final listing = RuTrackerService.parseListing(
      '<table id="topics"><tr><td><a class="torTopic" href="viewtopic.php?t=12">Example album</a></td><td class="tor-size">1.5 GB</td><td class="seedmed">7</td></tr></table>',
      Uri.parse('https://rutracker.org/forum/viewforum.php?f=1660'),
    );
    expect(listing.releases.single.bytes, 1610612736);
    expect(listing.releases.single.seeders, 7);
  });
  test(
    'Cyrillic search uses CP1251, wildcard spaces and music restriction',
    () async {
      final transport = FixtureTransport(
        (uri) => uri.path.endsWith('index.php') ? index : tracker,
      );
      final service = RuTrackerService(transport: transport);
      await service.refresh();
      expect(
        service.searchPath('Кино альбом'),
        contains('nm=%CA%E8%ED%EE%25%E0%EB%FC%E1%EE%EC'),
      );
      expect(service.searchPath('Кино альбом'), contains('f=1698%2C1660'));
      expect((await service.search('Example')).releases.length, 1);
      expect(service.username, 'Listener');
    },
  );
  test(
    'search login and Cloudflare require a concrete connection action',
    () async {
      var content = index;
      final service = RuTrackerService(
        transport: FixtureTransport((_) => content),
      );
      await service.refresh();
      content = '<input name="login_username">';
      await expectLater(
        service.search('Artist'),
        throwsA(
          isA<CatalogException>().having((e) => e.connect, 'connect', true),
        ),
      );
      content =
          '<title>Just a moment...</title><div id="challenge-form"></div>';
      await expectLater(
        service.refresh(),
        throwsA(
          isA<CatalogException>().having((e) => e.connect, 'connect', true),
        ),
      );
    },
  );
  test(
    'topic resolves magnet only on selection, cache contains catalog metadata',
    () async {
      final root = await Directory.systemTemp.createTemp('mumpa-catalog-');
      final transport = FixtureTransport(
        (uri) => uri.path.endsWith('index.php')
            ? index
            : '<table class="attach"><a class="magnet-link" href="magnet:?xt=urn:btih:abc&amp;dn=Album">magnet</a></table>',
      );
      final service = RuTrackerService(
        transport: transport,
        cacheDirectory: root,
      );
      try {
        await service.refresh();
        expect(transport.requests.length, 1);
        expect(
          await service.magnet(
            const SearchRelease(
              title: 'Album',
              link: 'https://rutracker.org/forum/viewtopic.php?t=42',
              rutracker: true,
            ),
          ),
          'magnet:?xt=urn:btih:abc&dn=Album',
        );
        final restored = RuTrackerService(
          cacheDirectory: root,
          transport: transport,
        );
        await restored.restore();
        expect(restored.sections.single.children.length, 2);
        await expectLater(
          service.magnet(
            const SearchRelease(
              title: 'bad',
              link: 'https://other.example/forum/viewtopic.php?t=1',
            ),
          ),
          throwsA(isA<CatalogException>()),
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
