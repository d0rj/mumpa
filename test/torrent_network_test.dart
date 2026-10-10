import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/data/torrent_network.dart';

void main() {
  test(
    'system route does not enumerate or select a physical interface',
    () async {
      var calls = 0;
      Future<List<TorrentNetwork>> enumerate() async {
        calls++;
        return [const TorrentNetwork('Wi-Fi', '192.0.2.10')];
      }

      expect(await resolveTorrentNetwork(null, list: enumerate), isNull);
      expect(await resolveTorrentNetwork('', list: enumerate), isNull);
      expect(calls, 0);
    },
  );

  test('resolves a saved name against the current DHCP address', () async {
    var address = '192.0.2.10';
    Future<List<TorrentNetwork>> enumerate() async => [
      const TorrentNetwork('VPN', '198.51.100.20'),
      TorrentNetwork('Wi-Fi', address),
    ];
    expect(await resolveTorrentNetwork('Wi-Fi', list: enumerate), address);
    address = '192.0.2.11';
    expect(await resolveTorrentNetwork('Wi-Fi', list: enumerate), address);
  });

  test(
    'an absent selected interface never falls back to VPN or Wi-Fi',
    () async {
      await expectLater(
        resolveTorrentNetwork(
          'Missing',
          list: () async => [const TorrentNetwork('Wi-Fi', '192.0.2.10')],
        ),
        throwsA(predicate((e) => e.toString().contains('Missing'))),
      );
    },
  );

  test(
    'explicit selection rejects unspecified, loopback and IPv6 addresses',
    () async {
      for (final address in ['0.0.0.0', '127.0.0.1', '::1', 'invalid']) {
        await expectLater(
          resolveTorrentNetwork(
            'Selected',
            list: () async => [TorrentNetwork('Selected', address)],
          ),
          throwsStateError,
        );
      }
    },
  );
}
