import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mumpa/data/catalog_repository.dart';
import 'package:mumpa/data/deezer_catalog_repository.dart';
import 'package:mumpa/data/media_cache.dart';
import 'package:mumpa/data/music_metadata_repository.dart';
import 'package:mumpa/domain/catalog_matching.dart';
import 'package:mumpa/domain/models.dart';
import 'package:mumpa/domain/music_metadata.dart';

class _ProbeClient extends http.BaseClient {
  final inner = http.Client();
  final requests = <Map<String, Object?>>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      final response = await inner.send(request);
      requests.add({
        'url': request.url.toString(),
        'status': response.statusCode,
      });
      return response;
    } catch (error) {
      requests.add({'url': request.url.toString(), 'error': error.toString()});
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}

List<MusicRecording> recordings(Map sample) {
  final all = <String, MusicRecording>{};
  for (final row in [
    ...sample['search'] as List,
    ...sample['details'] as List,
  ]) {
    final recording = DeezerCatalogRepository.parseRecording(row as Map);
    all[recording.key] = recording;
  }
  return all.values.toList();
}

Track input(Map sample, int i) => Track.fromJson({
  'id': 'sample-$i',
  'source': 'local',
  'album': '',
  ...Map<String, dynamic>.from(sample['track'] as Map),
});

void main() {
  test(
    'reviewed public recordings reject wrong artists, durations and live variants',
    () async {
      final data =
          jsonDecode(
                await File(
                  'test/fixtures/catalog-deezer-20261117.json',
                ).readAsString(),
              )
              as Map;
      final samples = data['samples'] as List;
      var accepted = 0, rejectedNegatives = 0;
      for (var i = 0; i < samples.length; i++) {
        final sample = samples[i] as Map;
        final track = input(sample, i);
        final candidates = recordings(sample);
        final matches = rankCatalogMatches(track, candidates);
        final automatic = automaticCatalogMatch(matches);
        expect(
          automatic?.recording.keys.contains(sample['expectedId']) ?? false,
          sample['expectedAutomatic'],
          reason: sample['query'] as String,
        );
        if (automatic != null) accepted++;
        if (sample['expectedId'] != null) {
          expect(
            matches
                .take(5)
                .any((m) => m.recording.keys.contains(sample['expectedId'])),
            isTrue,
            reason: 'top-5 ${sample['query']}',
          );
        }
        for (final negative in [
          track.copyWith(artist: 'Другой исполнитель'),
          track.copyWith(durationMs: track.durationMs + 60000),
          track.copyWith(title: '${track.title} (Live at a different concert)'),
        ]) {
          expect(
            automaticCatalogMatch(rankCatalogMatches(negative, candidates)),
            isNull,
            reason: 'negative ${sample['query']}',
          );
          rejectedNegatives++;
        }
      }
      await Directory('test-output').create(recursive: true);
      await File('test-output/catalog-public-quality.json').writeAsString(
        jsonEncode({
          'sourceDate': '2026-11-17',
          'publicQueries': samples.length,
          'acceptedReferenceMetadata': accepted,
          'rejectedControlledNegatives': rejectedNegatives,
          'scope':
              'Reviewed provider metadata with controlled perturbations; not audio fingerprint ground truth',
        }),
      );
    },
  );

  test(
    'evaluate private real library samples without changing the profile',
    () async {
      final data =
          jsonDecode(
                await File(
                  'test-output/catalog-live-samples.json',
                ).readAsString(),
              )
              as Map;
      final samples = (data['samples'] as List)
          .where((s) => s['origin'] == 'library')
          .toList();
      final report = <Map<String, dynamic>>[];
      for (var i = 0; i < samples.length; i++) {
        final sample = samples[i] as Map;
        final track = input(sample, i);
        final matches = rankCatalogMatches(track, recordings(sample));
        final automatic = automaticCatalogMatch(matches);
        report.add({
          'index': i,
          'input': sample['track'],
          'automaticId': automatic?.recording.key,
          'top': matches
              .take(5)
              .map(
                (m) => {
                  'id': m.recording.key,
                  'title': m.recording.title,
                  'artists': m.recording.artists.map((a) => a.name).toList(),
                  'album': m.recording.albumTitles,
                  'durationMs': m.recording.durationMs,
                  'evidence': m.evidence,
                  'conflicts': m.conflicts,
                  'score': m.score,
                },
              )
              .toList(),
        });
      }
      await File('test-output/catalog-library-quality.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'samples': samples.length,
          'automatic': report.where((r) => r['automaticId'] != null).length,
          'scope':
              'Metadata agreement only; no audio identity verification; no production writes',
          'results': report,
        }),
      );
    },
    skip: !const bool.fromEnvironment('CATALOG_PRIVATE_EVALUATION'),
  );

  test(
    'real combined provider pipeline returns the Russian duet and preserves credits',
    () async {
      final root = await Directory('test-output').createTemp('catalog-live-');
      final probe = _ProbeClient();
      final mb = MusicMetadataRepository(
        cache: DiskMediaCache(root),
        client: probe,
      );
      final repo = CatalogRepository(musicBrainz: mb);
      try {
        const track = Track(
          id: 'live',
          title: 'Роженица в метро',
          artist: 'Ежемесячные feat. Блёв Мс',
          album: 'Короли Абстракта VI - Мультивселенная ЕЖЕ',
          source: TrackSource.local,
          durationMs: 240483,
        );
        final result = await repo.match(track);
        await File('test-output/catalog-provider-http.json').writeAsString(
          jsonEncode({
            'requests': probe.requests,
            'unavailable': result.unavailableProviders,
            'candidates': result.matches.map((m) => m.recording.key).toList(),
          }),
        );
        expect(
          result.matches.any(
            (m) => m.recording.keys.contains('deezer:3230194751'),
          ),
          isTrue,
        );
        final deezer = result.matches.firstWhere(
          (m) => m.recording.keys.contains('deezer:3230194751'),
        );
        expect(
          deezer.recording.artists.map((a) => a.name),
          contains('Блёв Мс'),
        );
        await File('test-output/catalog-provider-live.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'unavailable': result.unavailableProviders,
            'automaticId': result.automatic?.recording.key,
            'candidates': result.matches
                .map(
                  (m) => {
                    'recording': m.recording.toJson(),
                    'score': m.score,
                    'conflicts': m.conflicts,
                    'automatic': m.automatic,
                  },
                )
                .toList(),
          }),
        );
      } finally {
        repo.dispose();
        mb.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('CATALOG_LIVE_TEST'),
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'combined provider quality on public reference songs',
    () async {
      final data =
          jsonDecode(
                await File(
                  'test/fixtures/catalog-deezer-20261117.json',
                ).readAsString(),
              )
              as Map;
      final samples = data['samples'] as List;
      final root = await Directory(
        'test-output',
      ).createTemp('catalog-public-batch-');
      final mb = MusicMetadataRepository(cache: DiskMediaCache(root));
      final repo = CatalogRepository(musicBrainz: mb);
      final results = <Map<String, dynamic>>[];
      try {
        for (var i = 0; i < samples.length; i++) {
          final sample = samples[i] as Map;
          final result = await repo.match(input(sample, i));
          results.add({
            'index': i,
            'input': sample['track'],
            'unavailable': result.unavailableProviders,
            'automaticId': result.automatic?.recording.key,
            'candidates': result.matches
                .map(
                  (m) => {
                    'recording': m.recording.toJson(),
                    'score': m.score,
                    'conflicts': m.conflicts,
                    'automatic': m.automatic,
                  },
                )
                .toList(),
          });
          await File(
            'test-output/catalog-public-combined-quality.json',
          ).writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'checkedDate': '2026-11-17',
              'completed': results.length,
              'total': samples.length,
              'automatic': results
                  .where((r) => r['automaticId'] != null)
                  .length,
              'results': results,
            }),
          );
        }
      } finally {
        repo.dispose();
        mb.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('CATALOG_PUBLIC_LIVE_BATCH'),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
