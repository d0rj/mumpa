import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../domain/models.dart';
import 'source_operation.dart';
import 'torrent_metainfo.dart';

/// Public content-addressed metadata, never audio or a user's tracker URL.
/// Every returned file is checked against the requested BitTorrent infohash.
class MagnetMetainfoCache {
  static const origin = 'https://torrage.info';

  static Future<File?> resolve(
    http.Client client,
    Uri magnet,
    Directory directory, {
    SourceOperation? operation,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    operation?.check();
    final xt = magnet.queryParameters['xt'] ?? '';
    if (!RegExp(r'^urn:btih:[a-fA-F0-9]{40}$').hasMatch(xt)) return null;
    final hash = xt.substring('urn:btih:'.length).toLowerCase();
    final cached = File(p.join(directory.path, 'metainfo-$hash.torrent'));
    if (await cached.exists()) {
      try {
        if (await cached.length() > 16 * 1024 * 1024) {
          throw const FormatException('Metadata cache too large');
        }
        final bytes = await cached.readAsBytes();
        _validate(bytes, hash);
        operation?.check();
        final merged = addMagnetTrackers(bytes, magnet);
        if (!identical(merged, bytes)) {
          return await _store(
            directory,
            cached,
            merged,
            check: operation?.check,
          );
        }
        return cached;
      } on SourceCancelled {
        rethrow;
      } catch (_) {
        // Replace only this generated, hash-addressed cache after validation.
      }
    }
    final scope = SourceOperation();
    final deadline = Timer(timeout, scope.cancel);
    final abort = Future.any([
      scope.whenCancelled,
      if (operation != null) operation.whenCancelled,
    ]);
    Future<Uint8List> get(
      Uri uri,
      int limit, {
      String? referer,
      bool download = false,
      int redirects = 0,
    }) async {
      operation?.check();
      scope.check();
      final request = http.AbortableRequest('GET', uri, abortTrigger: abort)
        ..followRedirects = false
        ..headers['accept'] = '*/*';
      if (referer != null) request.headers['referer'] = referer;
      final response = await client.send(request);
      if (download &&
          {301, 302, 303, 307, 308}.contains(response.statusCode) &&
          redirects < 3 &&
          response.headers['location'] != null) {
        await response.stream.listen((_) {}).cancel();
        final next = uri.resolve(response.headers['location']!);
        if (next.scheme != 'https' ||
            next.port != 443 ||
            next.userInfo.isNotEmpty ||
            (next.host != 'torrage.info' &&
                !RegExp(r'^t\d{1,2}\.torrage\.info$').hasMatch(next.host))) {
          throw const FormatException('Untrusted metainfo redirect');
        }
        return get(
          next,
          limit,
          referer: referer,
          download: true,
          redirects: redirects + 1,
        );
      }
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw HttpException('Metainfo cache: HTTP ${response.statusCode}');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        operation?.check();
        scope.check();
        bytes.add(chunk);
        if (bytes.length > limit) {
          throw const FormatException('Metadata response too large');
        }
      }
      return bytes.takeBytes();
    }

    Future<File> fetch() async {
      final page = Uri.parse(
        '$origin/torrent.php',
      ).replace(queryParameters: {'h': hash.toUpperCase()});
      final doc = html.parse(utf8.decode(await get(page, 256 * 1024)));
      Uri? control;
      for (final script in doc.querySelectorAll('script[src]')) {
        final uri = page.resolve(script.attributes['src']!);
        if (uri.origin == origin &&
            uri.path == '/torrent.php' &&
            uri.queryParameters['h']?.toLowerCase() == hash &&
            RegExp(r'^\d{1,20}$').hasMatch(uri.queryParameters['ttl'] ?? '')) {
          control = uri;
          break;
        }
      }
      if (control == null) {
        throw const FormatException('No public metainfo link');
      }
      // Read only the public download-link parameter; no site/ad JS is run.
      final text = utf8.decode(await get(control, 4096));
      final encoded = RegExp(
        r'getTTL\(\s*"([A-Za-z0-9_-]{10,256})"\s*\)',
      ).firstMatch(text)?.group(1);
      if (encoded == null) {
        throw const FormatException('Unknown public link format');
      }
      final ttl = encoded.codeUnits
          .map((value) {
            if (value >= 65 && value <= 90) return 65 + (value - 65 + 14) % 26;
            if (value >= 97 && value <= 122) return 97 + (value - 97 + 14) % 26;
            return value;
          })
          .toList()
          .reversed;
      final download = Uri.parse('$origin/download.php').replace(
        queryParameters: {
          'h': hash.toUpperCase(),
          'ttl': String.fromCharCodes(ttl),
        },
      );
      final downloaded = await get(
        download,
        16 * 1024 * 1024,
        referer: page.toString(),
        download: true,
      );
      _validate(downloaded, hash);
      // Keep the selected source's anonymous announce parameters: cached
      // torrents often contain an old tracker without the magnet query.
      final bytes = addMagnetTrackers(downloaded, magnet);
      operation?.check();
      scope.check();
      return _store(
        directory,
        cached,
        bytes,
        check: () {
          operation?.check();
          scope.check();
        },
      );
    }

    try {
      final pending = fetch();
      return await (operation?.wait(pending) ?? pending).timeout(timeout);
    } catch (_) {
      operation?.check();
      return null; // Unavailable cache never disables normal peer discovery.
    } finally {
      deadline.cancel();
      scope.cancel();
    }
  }

  static void _validate(Uint8List bytes, String hash) {
    final info = readTorrentMetainfo(bytes);
    if (info.hash != hash ||
        !info.files.any((file) => isAudioPath(file.path))) {
      throw const FormatException(
        'Metainfo hash/content does not match requested music',
      );
    }
  }

  static Future<File> _store(
    Directory directory,
    File cached,
    Uint8List bytes, {
    void Function()? check,
  }) async {
    await directory.create(recursive: true);
    final staging = await directory.createTemp('metainfo-stage-');
    try {
      final staged = File(p.join(staging.path, 'source.torrent'));
      await staged.writeAsBytes(bytes, flush: true);
      check?.call();
      if (await cached.exists()) await cached.delete();
      await staged.rename(cached.path);
      return cached;
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
