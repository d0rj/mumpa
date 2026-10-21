Map<String, dynamic> validatedSmartRule(Map raw) {
  final result = <String, dynamic>{};
  for (final key in ['liked', 'offline', 'unplayed']) {
    if (raw[key] != null && raw[key] is! bool) {
      throw const FormatException('Повреждены условия умного плейлиста.');
    }
    if (raw[key] is bool) result[key] = raw[key];
  }
  final artist = raw['artist'];
  if (artist != null && (artist is! String || artist.length > 256)) {
    throw const FormatException('Повреждён исполнитель в условии.');
  }
  if (artist is String) result['artist'] = artist;
  for (final key in [
    'fromYear',
    'toYear',
    'notPlayedDays',
    'addedDays',
    'limit',
  ]) {
    final value = raw[key];
    if (value == null) continue;
    if (value is! int ||
        value < (key == 'limit' ? 1 : 0) ||
        value > (key == 'limit' ? 5000 : 9999)) {
      throw const FormatException('Повреждены числовые условия плейлиста.');
    }
    result[key] = value;
  }
  if (result['fromYear'] != null &&
      result['toYear'] != null &&
      (result['fromYear'] as int) > (result['toYear'] as int)) {
    throw const FormatException('Неверный диапазон лет.');
  }
  if (raw['sort'] != null &&
      !['title', 'rare', 'recent'].contains(raw['sort'])) {
    throw const FormatException('Неизвестная сортировка плейлиста.');
  }
  result['sort'] = raw['sort'] ?? 'title';
  return Map.unmodifiable(result);
}
