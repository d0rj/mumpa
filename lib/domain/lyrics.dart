class LyricLine {
  const LyricLine(this.time, this.text);
  final Duration time;
  final String text;
}

class Lyrics {
  Lyrics(this.plain, this.lines);
  final String plain;
  final List<LyricLine> lines;
  bool get synced => lines.isNotEmpty;
  static Lyrics parse(String text) {
    final lines = <LyricLine>[];
    final offset =
        int.tryParse(
          RegExp(
                r'\[offset:([+-]?\d+)\]',
                caseSensitive: false,
              ).firstMatch(text)?.group(1) ??
              '',
        ) ??
        0;
    final stamp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
    for (final row in text.split(RegExp(r'\r?\n'))) {
      final words = row.replaceAll(stamp, '').trim();
      for (final match in stamp.allMatches(row)) {
        final seconds = int.parse(match[2]!);
        if (seconds >= 60) continue;
        final fraction = (match[3] ?? '').padRight(3, '0');
        final time =
            int.parse(match[1]!) * 60000 +
            seconds * 1000 +
            (int.tryParse(fraction) ?? 0) +
            offset;
        lines.add(
          LyricLine(Duration(milliseconds: time < 0 ? 0 : time), words),
        );
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return Lyrics(text, List.unmodifiable(lines));
  }

  int indexAt(Duration position) {
    var low = 0, high = lines.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (lines[mid].time <= position) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low - 1;
  }
}
