import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:enough_convert/windows.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../domain/models.dart';

class CatalogException implements Exception {
  const CatalogException(this.message, {this.connect = false});
  final String message;
  final bool connect;
  @override
  String toString() => message;
}

abstract class CatalogTransport {
  Future<String> load(Uri uri);
  Future<void> connect(Uri uri);
  Future<void> logout(Uri origin);
  Future<void> dispose();
}

// Useful for integrations without a browser and deterministic parser tests.
class HttpCatalogTransport implements CatalogTransport {
  HttpCatalogTransport({http.Client? client})
    : _client = client ?? http.Client();
  final http.Client _client;
  @override
  Future<String> load(Uri uri) async {
    final response = await _client
        .get(
          uri,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
          },
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode == 403 || response.statusCode == 503) {
      throw const CatalogException(
        'RuTracker запрашивает проверку доступа. Открой сайт в Mumpa и пройди её.',
        connect: true,
      );
    }
    if (response.statusCode != 200) {
      throw CatalogException(
        'RuTracker ответил HTTP ${response.statusCode}. Попробуй обновить каталог.',
      );
    }
    return response.headers['content-type']?.contains('utf-8') == true
        ? utf8.decode(response.bodyBytes)
        : const Windows1251Codec().decode(response.bodyBytes);
  }

  @override
  Future<void> connect(Uri uri) async =>
      throw const CatalogException('Для входа нужен встроенный браузер.');
  @override
  Future<void> logout(Uri origin) async {}
  @override
  Future<void> dispose() async => _client.close();
}

class CatalogSection {
  const CatalogSection({
    required this.title,
    required this.path,
    this.children = const [],
  });
  final String title, path;
  final List<CatalogSection> children;
  Map<String, Object> toJson() => {
    'title': title,
    'path': path,
    'children': children.map((c) => c.toJson()).toList(),
  };
  factory CatalogSection.fromJson(Map<String, dynamic> json) => CatalogSection(
    title: json['title'] as String,
    path: json['path'] as String,
    children: (json['children'] as List? ?? [])
        .map(
          (c) => CatalogSection.fromJson(Map<String, dynamic>.from(c as Map)),
        )
        .toList(),
  );
}

class CatalogListing {
  const CatalogListing({
    this.sections = const [],
    this.releases = const [],
    this.nextPath,
  });
  final List<CatalogSection> sections;
  final List<SearchRelease> releases;
  final String? nextPath;
}

class RuTrackerService {
  RuTrackerService({
    CatalogTransport? transport,
    this.cacheDirectory,
    String baseUrl = 'https://rutracker.org/',
  }) : transport = transport ?? HttpCatalogTransport(),
       _base = Uri.parse(baseUrl);
  final CatalogTransport transport;
  final Directory? cacheDirectory;
  Uri _base;
  Uri get base => _base;
  String? username;
  List<CatalogSection> sections = [];
  final Set<String> _audioForums = {};
  static const musicCategoryIds = {'8', '35', '31', '22', '23', '37'};
  static const mirrors = [
    'https://rutracker.org/',
    'https://rutracker.net/',
    'https://rutracker.nl/',
  ];
  Uri uri(String path) => _base.resolve('forum/$path');

  Future<void> restore() async {
    final cache = cacheDirectory;
    if (cache == null) return;
    try {
      final json =
          jsonDecode(
                await File(p.join(cache.path, 'sections.json')).readAsString(),
              )
              as Map;
      sections = (json['sections'] as List)
          .map(
            (s) => CatalogSection.fromJson(Map<String, dynamic>.from(s as Map)),
          )
          .toList();
      _rememberForums(sections);
    } on FileSystemException {
      // A fresh installation has no cached catalog.
    } on FormatException {
      // Replace incomplete catalog metadata with the next successful response.
    }
  }

  Future<String> _load(String path) async {
    final text = await transport.load(uri(path));
    final doc = html.parse(text);
    if (doc.querySelector('#challenge-form, #cf-challenge-running') != null ||
        (doc.querySelector('title')?.text.contains('Just a moment') ?? false)) {
      throw const CatalogException(
        'RuTracker запрашивает проверку доступа. Нажми «Открыть RuTracker», пройди проверку и вернись в приложение.',
        connect: true,
      );
    }
    username = doc.querySelector('#logged-in-username')?.text.trim();
    return text;
  }

  Future<List<CatalogSection>> refresh() async {
    sections = parseIndex(await _load('index.php'));
    if (sections.isEmpty) {
      throw const CatalogException(
        'Не удалось прочитать музыкальные разделы RuTracker. Попробуй обновить каталог.',
      );
    }
    _rememberForums(sections);
    final cache = cacheDirectory;
    if (cache != null) {
      await cache.create(recursive: true);
      final file = File(p.join(cache.path, 'sections.json'));
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({'sections': sections.map((s) => s.toJson()).toList()}),
      );
      await temp.rename(file.path);
    }
    return sections;
  }

  void _rememberForums(List<CatalogSection> values) {
    for (final section in values) {
      final id = Uri.parse(section.path).queryParameters['f'];
      if (id != null) _audioForums.add(id);
      _rememberForums(section.children);
    }
  }

  Future<CatalogListing> browse(String path) async {
    final text = await _load(path);
    final result = parseListing(text, uri(path));
    _rememberForums(result.sections);
    if (result.sections.isEmpty &&
        result.releases.isEmpty &&
        username == null) {
      // The tracker displays a login form for restricted forums.
      final doc = html.parse(text);
      if (doc.querySelector('input[name="login_username"]') != null) {
        throw const CatalogException(
          'Для этого раздела войди в свой аккаунт RuTracker.',
          connect: true,
        );
      }
    }
    return result;
  }

  String searchPath(String query, {int offset = 0}) {
    final terms = query.trim().replaceAll(
      RegExp(r'[^a-zA-Zа-яА-ЯёЁ0-9]+'),
      '%',
    );
    final codec = const Windows1251Codec();
    final params = <String, String>{
      'nm': terms,
      'o': '10',
      's': '2',
      'start': '$offset',
    };
    if (_audioForums.isNotEmpty) params['f'] = _audioForums.join(',');
    return 'tracker.php?${params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value, encoding: codec)}').join('&')}';
  }

  Future<CatalogListing> search(String query, {int offset = 0}) async {
    if (_audioForums.isEmpty) await refresh();
    final path = searchPath(query, offset: offset);
    final text = await _load(path);
    final doc = html.parse(text);
    if (username == null && doc.querySelector('#tor-tbl') == null) {
      throw const CatalogException(
        'Поиск RuTracker доступен после входа. Нажми «Войти в RuTracker». Жанры можно просматривать без аккаунта.',
        connect: true,
      );
    }
    return parseListing(text, uri(path));
  }

  Future<String> magnet(SearchRelease release) async {
    final target = Uri.parse(release.link);
    if (target.host != _base.host || !target.path.endsWith('/viewtopic.php')) {
      throw const CatalogException('Некорректная ссылка на раздачу RuTracker.');
    }
    final text = await _load('viewtopic.php?${target.query}');
    final doc = html.parse(text);
    final link = doc
        .querySelector(
          'a.magnet-link[href^="magnet:?"], a[href^="magnet:?xt=urn:btih:"]',
        )
        ?.attributes['href'];
    if (link == null) {
      throw CatalogException(
        username == null
            ? 'Для доступа к раздаче войди в RuTracker.'
            : 'У этой раздачи не найдена magnet-ссылка. Возможно, она удалена.',
        connect: username == null,
      );
    }
    return link;
  }

  Future<void> connect({bool login = true}) =>
      transport.connect(uri(login ? 'login.php' : 'index.php'));
  Future<void> logout() async {
    await transport.logout(_base);
    username = null;
  }

  Future<void> setMirror(String url) async {
    if (!mirrors.contains(url)) {
      throw const CatalogException('Выбери одно из зеркал RuTracker.');
    }
    _base = Uri.parse(url);
    username = null;
  }

  Future<void> dispose() => transport.dispose();

  static String _text(Element e) =>
      e.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  static bool _musicForum(Element a) => !RegExp(
    r'помощ|предложен|обсужден|правила|общение',
    caseSensitive: false,
  ).hasMatch(_text(a));
  static List<CatalogSection> parseIndex(String text) {
    final doc = html.parse(text);
    final result = <CatalogSection>[];
    for (final category in doc.querySelectorAll('.category')) {
      final heading = category.querySelector('.cat_title a');
      if (heading == null) continue;
      final path = heading.attributes['href'] ?? '';
      if (!musicCategoryIds.contains(
        Uri.tryParse(path)?.queryParameters['c'],
      )) {
        continue;
      }
      final children = <CatalogSection>[];
      final seen = <String>{};
      for (final a in category.querySelectorAll('.forumlink a, .sf_title a')) {
        final href = a.attributes['href'] ?? '';
        if (href.startsWith('viewforum.php?f=') &&
            seen.add(href) &&
            _musicForum(a)) {
          children.add(CatalogSection(title: _text(a), path: href));
        }
      }
      result.add(
        CatalogSection(title: _text(heading), path: path, children: children),
      );
    }
    return result;
  }

  static CatalogListing parseListing(String text, Uri page) {
    final doc = html.parse(text);
    final index = parseIndex(text);
    if (page.path.endsWith('index.php')) {
      final c = page.queryParameters['c'];
      return CatalogListing(
        sections: index
            .where((i) => Uri.parse(i.path).queryParameters['c'] == c)
            .expand((s) => s.children)
            .toList(),
      );
    }
    final sections = <CatalogSection>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('.forumlink a, .sf_title a')) {
      final href = a.attributes['href'] ?? '';
      if (href.startsWith('viewforum.php?f=') &&
          seen.add(href) &&
          _musicForum(a)) {
        sections.add(CatalogSection(title: _text(a), path: href));
      }
    }
    final releases = <SearchRelease>[];
    for (final row in doc.querySelectorAll(
      '#tor-tbl tr, #topics tr, .forum tr',
    )) {
      final a = row.querySelector('a.tLink, a.torTopic');
      if (a == null) continue;
      final href = a.attributes['href'] ?? '';
      if (!href.contains('viewtopic.php?t=')) continue;
      final size = row.querySelector('.tor-size');
      final columns = row.children.where((e) => e.localName == 'td').toList();
      final seed =
          row.querySelector('.seedmed, .seed') ??
          (columns.length > 6 ? columns[6].querySelector('b') : null);
      releases.add(
        SearchRelease(
          title: _text(a),
          link: page.resolve(href).toString(),
          rutracker: true,
          bytes:
              int.tryParse(size?.attributes['data-ts_text'] ?? '') ??
              _size(size?.text ?? ''),
          seeders:
              int.tryParse(
                seed?.text.replaceAll(RegExp(r'[^0-9]'), '') ?? '',
              ) ??
              0,
          category: row.querySelector('.f-name a')?.text.trim() ?? '',
        ),
      );
    }
    final current = int.tryParse(page.queryParameters['start'] ?? '0') ?? 0;
    String? next;
    var minimum = 1 << 30;
    for (final a in doc.querySelectorAll('.nav a, .pg a, .pagination a')) {
      final link = page.resolve(a.attributes['href'] ?? '');
      final start = int.tryParse(link.queryParameters['start'] ?? '') ?? 0;
      if (link.path == page.path && start > current && start < minimum) {
        minimum = start;
        next = '${p.basename(link.path)}?${link.query}';
      }
    }
    return CatalogListing(
      sections: sections,
      releases: releases,
      nextPath: next,
    );
  }

  static int _size(String value) {
    final match = RegExp(
      r'([0-9.,]+)\s*(KB|MB|GB|TB|КБ|МБ|ГБ)',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return 0;
    final number = double.tryParse(match[1]!.replaceAll(',', '.')) ?? 0;
    final unit = match[2]!.toUpperCase();
    final exponent =
        {'KB': 1, 'КБ': 1, 'MB': 2, 'МБ': 2, 'GB': 3, 'ГБ': 3, 'TB': 4}[unit] ??
        0;
    return (number * (1 << (10 * exponent))).round();
  }
}
