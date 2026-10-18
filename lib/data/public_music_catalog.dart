import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/models.dart';
import 'source_operation.dart';

/// Public, documented search API. No account, cookies or local helper needed.
/// https://knaben.org/api/v1/
class PublicMusicCatalog {
  static const endpoint = 'https://api.knaben.org/v1';
  static const musicCategories = {1001000, 1002000}; // MP3 / lossless only.

  static Future<List<SearchRelease>> search(
    http.Client client,
    String query, {
    SourceOperation? operation,
  }) async {
    final results = await _request(client, query, operation: operation);
    if (results.isNotEmpty || query.trim().isEmpty) return results;
    // Knaben's combined age/risk filter also hides active music releases with
    // a zero risk score. A bounded second lookup admits only explicit zeroes;
    // unknown and nonzero scores stay excluded, as do nonmusic categories.
    return _request(client, query, operation: operation, zeroRiskOnly: true);
  }

  static Future<List<SearchRelease>> _request(
    http.Client client,
    String query, {
    SourceOperation? operation,
    bool zeroRiskOnly = false,
  }) async {
    operation?.check();
    final request =
        http.AbortableRequest(
            'POST',
            Uri.parse(endpoint),
            abortTrigger: operation?.whenCancelled,
          )
          ..headers['content-type'] = 'application/json; charset=utf-8'
          ..headers['accept'] = 'application/json'
          ..body = jsonEncode({
            'search_type': '100%',
            'search_field': 'title',
            if (query.trim().isNotEmpty) 'query': query.trim(),
            'categories': musicCategories.toList(),
            'order_by': 'seeders',
            'order_direction': 'desc',
            'size': 60,
            'hide_unsafe': !zeroRiskOnly,
            'hide_xxx': true,
          });
    try {
      final pending = client.send(request).then(http.Response.fromStream);
      final response = await (operation?.wait(pending) ?? pending).timeout(
        const Duration(seconds: 20),
      );
      operation?.check();
      if (response.statusCode != 200) {
        throw HttpException(
          response.statusCode == 429
              ? 'Каталог временно ограничил запросы. Повтори поиск чуть позже.'
              : 'Музыкальный каталог недоступен (HTTP ${response.statusCode}). Повтори поиск или выбери другой источник.',
        );
      }
      return parse(
        jsonDecode(utf8.decode(response.bodyBytes)),
        zeroRiskOnly: zeroRiskOnly,
      );
    } on http.ClientException {
      operation?.check();
      throw const HttpException(
        'Не удалось подключиться к музыкальному каталогу. Проверь интернет или выбери другой источник.',
      );
    } on TimeoutException {
      throw const HttpException(
        'Музыкальный каталог не ответил за 20 секунд. Повтори поиск или выбери другой источник.',
      );
    } on FormatException {
      throw const HttpException(
        'Не удалось прочитать ответ музыкального каталога.',
      );
    }
  }

  static List<SearchRelease> parse(dynamic value, {bool zeroRiskOnly = false}) {
    if (value is! Map || value['hits'] is! List) {
      throw const FormatException('Invalid catalog response');
    }
    final seen = <String>{};
    final result = <SearchRelease>[];
    for (final hit in value['hits'] as List) {
      if (hit is! Map || hit['title'] is! String) continue;
      if (zeroRiskOnly && hit['virusDetection'] != 0) continue;
      final categories = hit['categoryId'];
      if (categories is! List || !categories.any(musicCategories.contains)) {
        continue;
      }
      final hash = hit['hash']?.toString() ?? '';
      var magnet = hit['magnetUrl'] is String ? hit['magnetUrl'] as String : '';
      if (magnet.isEmpty && RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(hash)) {
        magnet = Uri(
          scheme: 'magnet',
          queryParameters: {
            'xt': 'urn:btih:$hash',
            'dn': hit['title'] as String,
          },
        ).toString();
      }
      final uri = Uri.tryParse(magnet);
      final xt = uri?.queryParameters['xt'] ?? '';
      if (uri?.scheme != 'magnet' ||
          !RegExp(
            r'^urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})$',
          ).hasMatch(xt)) {
        continue;
      }
      if (!seen.add(xt.toLowerCase())) continue;
      final details = Uri.tryParse(hit['details']?.toString() ?? '');
      result.add(
        SearchRelease(
          title: (hit['title'] as String).trim(),
          link: magnet,
          magnetLink: magnet,
          bytes: (hit['bytes'] is num ? (hit['bytes'] as num).toInt() : 0)
              .clamp(0, 1 << 53),
          seeders: (hit['seeders'] is num ? (hit['seeders'] as num).toInt() : 0)
              .clamp(0, 1 << 31),
          seedersKnown: hit['seeders'] is num,
          category: hit['category']?.toString() ?? '',
          indexerName: 'Knaben · ${hit['tracker'] ?? 'музыка'}',
          detailsUrl:
              details != null && {'http', 'https'}.contains(details.scheme)
              ? details.toString()
              : '',
        ),
      );
    }
    result.sort((a, b) => b.seeders.compareTo(a.seeders));
    return result;
  }
}
