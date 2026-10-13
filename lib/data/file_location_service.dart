import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/models.dart';
import 'library_repository.dart';

class FileLocationService {
  static const _channel = MethodChannel('app.mumpa/windows_player');
  static bool get available => Platform.isWindows;

  static bool canReveal(LibraryRepository library, Track track) =>
      available && library.localCopiesFor(track).isNotEmpty;

  static Future<void> revealTrack(
    LibraryRepository library,
    Track track,
  ) async {
    if (!available) return;
    final path = await library.localPathFor(track);
    if (path == null) {
      throw const FileSystemException('Файл трека не найден на диске.');
    }
    await _channel.invokeMethod<void>('revealFile', File(path).absolute.path);
  }
}
