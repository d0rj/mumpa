import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../domain/models.dart';
import 'source_operation.dart';

/// Anonymous music-only search. HTML is parsed as data, never executed.
class RutorMusicCatalog {
  static const origins = ['https://rutor.info', 'https://rutor.is'];

  static Future<List<SearchRelease>> search(
    http.Client client,
    String query, {
    SourceOperation? operation,
  }) async {
    if (query.trim().isEmpty) return [];
    for (final origin in origins) {
      operation?.check();
      final uri = Uri.parse(origin).replace(
        // Category 2 is music; 100 searches titles, 2 sorts by seeders.
        pathSegments: ['search', '0', '2', '100', '2', query.trim(), ''],
      );
      try {
        final request = http.AbortableRequest(
          'GET',
          uri,
          abortTrigger: operation?.whenCancelled,
        )..headers['accept'] = 'text/html';
        final pending = () async {
          final response = await client.send(request);
          if (response.statusCode != 200) {
            await response.stream.drain<void>();
            throw HttpException('RuTor: HTTP ${response.statusCode}.');
          }
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response.stream) {
            operation?.check();
            bytes.add(chunk);
            if (bytes.length > 2 * 1024 * 1024) {
              throw const FormatException('RuTor: слишком большой ответ.');
            }
          }
          return parse(utf8.decode(bytes.takeBytes()), Uri.parse(origin));
        }();
        return await (operation?.wait(pending) ?? pending).timeout(
          const Duration(seconds: 8),
        );
      } on SourceCancelled {
        rethrow;
      } catch (_) {
        operation?.check();
        if (origin == origins.last) {
          throw const HttpException('Не удалось подключиться к RuTor.');
        }
      }
    }
    return [];
  }

  static List<SearchRelease> parse(String text, Uri origin) {
    final index = html.parse(text).querySelector('#index');
    if (index == null) {
      throw const FormatException('RuTor вернул страницу без результатов.');
    }
    final result = <SearchRelease>[];
    final seen = <String>{};
    for (final row in index.querySelectorAll('tr')) {
      final title = row.querySelector('a[href^="/torrent/"]');
      final name = title?.text.trim() ?? '';
      // RuTor's music section also contains concert videos. Keep audio releases.
      if (!RegExp(
            r'(?:^|[^a-zа-яё0-9])(mp3|мр3|flac|ape|alac|wav|wavpack|wv|aac|m4a|ogg|opus)(?:$|[^a-zа-яё0-9])',
            caseSensitive: false,
          ).hasMatch(name) ||
          RegExp(
            r'\b(webrip|web-dl|bdrip|bluray|hdtv|dvdrip|720p|1080p|2160p)\b',
            caseSensitive: false,
          ).hasMatch(name)) {
        continue;
      }
      final magnet = row
          .querySelector('a[href^="magnet:?"]')
          ?.attributes['href'];
      final xt = Uri.tryParse(magnet ?? '')?.queryParameters['xt'] ?? '';
      if (title == null ||
          title.text.trim().isEmpty ||
          !RegExp(r'^urn:btih:[a-fA-F0-9]{40}$').hasMatch(xt) ||
          !seen.add(xt.toLowerCase())) {
        continue;
      }
      final sizeText = row.querySelectorAll('td').map((e) => e.text).join(' ');
      final size = RegExp(
        r'(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|kB|B)\b',
        caseSensitive: false,
      ).firstMatch(sizeText);
      final scale = const {
        'tb': 1024 * 1024 * 1024 * 1024,
        'gb': 1024 * 1024 * 1024,
        'mb': 1024 * 1024,
        'kb': 1024,
        'b': 1,
      }[size?.group(2)?.toLowerCase()];
      final seedText = row.querySelector('span.green')?.text.trim();
      final seeders = int.tryParse(
        (seedText ?? '').replaceAll(RegExp(r'\s'), ''),
      );
      final download = origin.resolve(
        row.querySelector('a.downgif')?.attributes['href'] ?? '',
      );
      final trustedDownload =
          {
            'rutor.info',
            'rutor.is',
            'd.rutor.info',
            'd.rutor.is',
          }.contains(download.host) &&
          RegExp(r'^/download/\d+$').hasMatch(download.path);
      result.add(
        SearchRelease(
          title: name,
          link: trustedDownload
              ? download.replace(scheme: 'https').toString()
              : magnet!,
          magnetLink: magnet,
          detailsUrl: origin.resolve(title.attributes['href']!).toString(),
          bytes: size == null || scale == null
              ? 0
              : ((double.tryParse(size.group(1)!.replaceAll(',', '.')) ?? 0) *
                        scale)
                    .round(),
          seeders: seeders ?? 0,
          seedersKnown: seeders != null,
          category: 'Музыка',
          indexerName: 'RuTor',
        ),
      );
    }
    return result.take(50).toList();
  }
}
