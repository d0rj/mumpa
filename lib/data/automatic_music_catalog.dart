import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/models.dart';
import 'public_music_catalog.dart';
import 'rutor_music_catalog.dart';
import 'source_operation.dart';

class AutomaticMusicCatalog {
  static Future<List<SearchRelease>> search(
    http.Client client,
    String query, {
    SourceOperation? operation,
  }) async {
    operation?.check();
    if (query.trim().isEmpty) {
      return PublicMusicCatalog.search(client, query, operation: operation);
    }
    var failed = 0;
    Future<List<SearchRelease>> collect(
      Future<List<SearchRelease>> pending,
    ) async {
      try {
        return await pending;
      } on SourceCancelled {
        rethrow;
      } catch (_) {
        operation?.check();
        failed++;
        return [];
      }
    }

    final responses = await Future.wait([
      collect(PublicMusicCatalog.search(client, query, operation: operation)),
      collect(RutorMusicCatalog.search(client, query, operation: operation)),
    ]);
    operation?.check();
    final unique = <String, SearchRelease>{};
    for (final release in responses.expand((items) => items)) {
      final hash = Uri.tryParse(
        release.magnetLink ?? release.link,
      )?.queryParameters['xt']?.toLowerCase();
      final key = hash ?? release.link;
      final existing = unique[key];
      if (existing == null ||
          (existing.link.startsWith('magnet:') &&
              !release.link.startsWith('magnet:'))) {
        unique[key] = release;
      }
    }
    if (unique.isEmpty && failed > 0) {
      throw const HttpException(
        'Часть музыкальных каталогов недоступна. Повтори поиск: пустая выдача ещё не означает отсутствие музыки.',
      );
    }
    final results = unique.values.toList()
      ..sort((a, b) => b.seeders.compareTo(a.seeders));
    return results;
  }
}
