import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mumpa/data/app_update_service.dart';
import 'package:mumpa/ui/app_update_panel.dart';

void main() {
  late Directory root;
  late AppUpdateService updates;
  final payload = List.generate(8192, (i) => i % 251);
  var remoteVersion = '1.2.15+23';
  var body = payload;
  var manifestHash = sha256.convert(payload).toString();
  var manifestBytes = payload.length;
  var duplicate = false;
  var httpError = false;
  final requests = <Uri>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mumpa-updates-');
    remoteVersion = '1.2.15+23';
    body = payload;
    manifestHash = sha256.convert(payload).toString();
    manifestBytes = payload.length;
    duplicate = false;
    httpError = false;
    requests.clear();
    updates = AppUpdateService(
      root,
      installedVersion: () async => '1.2.14+22',
      target: () async => 'windows-x64.zip',
      clientFactory: () => MockClient((request) async {
        requests.add(request.url);
        if (httpError) return http.Response('unavailable', 503);
        if (request.url.path.endsWith('BUILD.json')) {
          return http.Response(jsonEncode({'version': remoteVersion}), 200);
        }
        if (request.url.path.endsWith('SHA256.json')) {
          final entry = {
            'file': 'Mumpa-${remoteVersion.split('+').first}-windows-x64.zip',
            'bytes': manifestBytes,
            'sha256': manifestHash,
          };
          return http.Response(jsonEncode([entry, if (duplicate) entry]), 200);
        }
        return http.Response.bytes(body, 200);
      }),
    );
  });
  tearDown(() async {
    updates.dispose();
    await root.delete(recursive: true);
  });

  test('numeric versions handle 1.2.9 to 1.2.10, build and downgrade', () {
    expect(
      AppUpdateService.compareVersions('1.2.10+1', '1.2.9+99'),
      greaterThan(0),
    );
    expect(
      AppUpdateService.compareVersions('1.2.14+23', '1.2.14+22'),
      greaterThan(0),
    );
    expect(AppUpdateService.compareVersions('1.1.99', '1.2.0'), lessThan(0));
    expect(
      () => AppUpdateService.compareVersions('1.2.15-rc1', '1.2.14'),
      throwsFormatException,
    );
  });
  test(
    'checks stable metadata then downloads, hashes and promotes the whole package',
    () async {
      await updates.check();
      expect(updates.available?.version, '1.2.15+23');
      await updates.download();
      expect(updates.error, isNull);
      expect(await updates.downloaded!.readAsBytes(), payload);
      expect(updates.received, payload.length);
      expect(
        root.listSync().where((file) => file.path.endsWith('.part')),
        isEmpty,
      );
      expect(requests.map((uri) => uri.host).toSet(), {'github.com'});
      expect(
        requests.last.path,
        '/d0rj/mumpa/releases/download/v1.2.15/Mumpa-1.2.15-windows-x64.zip',
      );
    },
  );
  test('same or older remote does not offer download', () async {
    for (final version in ['1.2.13+21', '1.2.14+22']) {
      remoteVersion = version;
      await updates.check();
      expect(updates.available, isNull);
      expect(updates.error, isNull);
    }
    expect(requests.length, 2);
  });
  test('verified package is available after a fresh check', () async {
    await updates.check();
    await updates.download();
    updates.downloaded = null;
    await updates.check();
    expect(updates.downloaded, isNotNull);
    expect(updates.status, contains('скачано и проверено'));
  });
  test(
    'private release switches to public assets without requiring GitHub CLI',
    () async {
      updates.dispose();
      var public = false;
      var privateCalls = 0;
      final build = jsonEncode({'version': '1.2.15+23'});
      final sums = jsonEncode([
        {
          'file': 'Mumpa-1.2.15-windows-x64.zip',
          'bytes': payload.length,
          'sha256': sha256.convert(payload).toString(),
        },
      ]);
      updates = AppUpdateService(
        root,
        installedVersion: () async => '1.2.14+22',
        target: () async => 'windows-x64.zip',
        clientFactory: () => MockClient((request) async {
          if (!public) return http.Response('private', 404);
          if (request.url.path.endsWith('BUILD.json')) {
            return http.Response(build, 200);
          }
          if (request.url.path.endsWith('SHA256.json')) {
            return http.Response(sums, 200);
          }
          return http.Response.bytes(payload, 200);
        }),
        privateApi: (path) async {
          privateCalls++;
          final content = path.endsWith('/latest')
              ? jsonEncode({
                  'tag_name': 'v1.2.15',
                  'draft': false,
                  'prerelease': false,
                  'assets': [
                    {'id': 1, 'name': 'BUILD.json'},
                    {'id': 2, 'name': 'SHA256.json'},
                    {'id': 3, 'name': 'Mumpa-1.2.15-windows-x64.zip'},
                  ],
                })
              : path.endsWith('/1')
              ? build
              : sums;
          return http.StreamedResponse(Stream.value(utf8.encode(content)), 200);
        },
      );
      await updates.check();
      expect(updates.error, isNull);
      expect(updates.available!.privateAssetPath, endsWith('/3'));
      expect(privateCalls, 3);
      public = true;
      await updates.check();
      expect(updates.error, isNull);
      expect(updates.available!.privateAssetPath, isNull);
      await updates.download();
      expect(updates.downloaded, isNotNull);
      expect(privateCalls, 3);
      expect(await updates.downloaded!.readAsBytes(), payload);
    },
  );
  test('duplicate manifest packages cannot be installed', () async {
    duplicate = true;
    await updates.check();
    expect(updates.available, isNull);
    expect(updates.error, contains('отсутствует'));
  });
  test('bad manifest SHA and impossible sizes are rejected', () async {
    manifestHash = 'no checksum';
    await updates.check();
    expect(updates.available, isNull);
    manifestHash = sha256.convert(payload).toString();
    manifestBytes = 2 * 1024 * 1024 * 1024;
    await updates.check();
    expect(updates.available, isNull);
  });
  test(
    'corruption with the same size leaves no installable file and can retry',
    () async {
      await updates.check();
      body = payload.reversed.toList();
      await updates.download();
      expect(updates.downloaded, isNull);
      expect(updates.error, contains('SHA-256'));
      expect(root.listSync(), isEmpty);
      body = payload;
      await updates.download();
      expect(updates.downloaded, isNotNull);
    },
  );
  test('truncated response leaves no installable file', () async {
    await updates.check();
    body = payload.sublist(0, 100);
    await updates.download();
    expect(updates.downloaded, isNull);
    expect(updates.error, contains('Размер'));
    expect(root.listSync(), isEmpty);
  });
  test('network failure is visible and retry checks successfully', () async {
    httpError = true;
    await updates.check();
    expect(updates.error, contains('503'));
    expect(updates.busy, isFalse);
    httpError = false;
    await updates.check();
    expect(updates.available, isNotNull);
    expect(updates.error, isNull);
  });
  test(
    'a changed downloaded package is rejected before starting an installer',
    () async {
      await updates.check();
      await updates.download();
      await updates.downloaded!.writeAsBytes(payload.reversed.toList());
      var quits = 0;
      await updates.install(
        quit: () async {
          quits++;
        },
      );
      expect(quits, 0);
      expect(updates.downloaded, isNull);
      expect(updates.error, contains('Пакет изменён'));
    },
  );
  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'update controls download and expose installer at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: AppUpdatePanel(
                  updates: updates,
                  quit: () async {},
                  autoCheck: true,
                  onAutoCheck: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('check-app-update')));
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (updates.busy) {
            if (DateTime.now().isAfter(deadline)) {
              throw StateError('Check timed out');
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await tester.pump();
        expect(find.textContaining('Доступна Mumpa'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('download-app-update')));
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (updates.busy) {
            if (DateTime.now().isAfter(deadline)) {
              throw StateError('Download timed out');
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await tester.pump();
        expect(
          find.byKey(const ValueKey('install-app-update')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
