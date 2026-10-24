/// Files as the studio and the animator write them: never half-written,
/// and never over something by accident.
library;

import 'dart:io';

/// [stem], or `stem_2`, `stem_3`… — the first name for which no
/// `<dir>/<name><suffix>` exists, for any of [suffixes].
String freeStem(String dir, String stem, List<String> suffixes) {
  bool taken(String name) =>
      suffixes.any((suffix) => File('$dir/$name$suffix').existsSync());
  if (!taken(stem)) return stem;
  for (var i = 2; i < 10000; i++) {
    if (!taken('${stem}_$i')) return '${stem}_$i';
  }
  return '${stem}_${DateTime.now().millisecondsSinceEpoch}';
}

/// Writes [bytes] to [file] so that it ends up either whole or as it was:
/// into a file beside it first, which then takes its place. A save that
/// fails half-way — a full disk, a crash — leaves the old file, not a
/// truncated one.
Future<void> writeAtomically(File file, List<int> bytes) async {
  final temp = File('${file.path}.saving');
  try {
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  } catch (_) {
    if (await temp.exists()) await temp.delete();
    rethrow;
  }
}

/// A file name made safe for any file system: what is not a letter, a
/// digit, `_` or `-` becomes `_`.
String safeFileName(String name) =>
    name.replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_');
