import 'pixel_buffer.dart';

/// A named list of colours.
class NamedPalette {
  const NamedPalette(this.name, this.colors);

  final String name;
  final List<int> colors;
}

/// Palettes to start from, and the file formats palettes travel in.
abstract final class Palettes {
  static const NamedPalette pico8 = NamedPalette('PICO-8', [
    0xFF000000, 0xFF1D2B53, 0xFF7E2553, 0xFF008751, //
    0xFFAB5236, 0xFF5F574F, 0xFFC2C3C7, 0xFFFFF1E8,
    0xFFFF004D, 0xFFFFA300, 0xFFFFEC27, 0xFF00E436,
    0xFF29ADFF, 0xFF83769C, 0xFFFF77A8, 0xFFFFCCAA,
  ]);

  static const NamedPalette sweetie16 = NamedPalette('Sweetie 16', [
    0xFF1A1C2C, 0xFF5D275D, 0xFFB13E53, 0xFFEF7D57, //
    0xFFFFCD75, 0xFFA7F070, 0xFF38B764, 0xFF257179,
    0xFF29366F, 0xFF3B5DC9, 0xFF41A6F6, 0xFF73EFF7,
    0xFFF4F4F4, 0xFF94B0C2, 0xFF566C86, 0xFF333C57,
  ]);

  static const NamedPalette db16 = NamedPalette('DawnBringer 16', [
    0xFF140C1C, 0xFF442434, 0xFF30346D, 0xFF4E4A4E, //
    0xFF854C30, 0xFF346524, 0xFFD04648, 0xFF757161,
    0xFF597DCE, 0xFFD27D2C, 0xFF8595A1, 0xFF6DAA2C,
    0xFFD2AA99, 0xFF6DC2CA, 0xFFDAD45E, 0xFFDEEED6,
  ]);

  static const NamedPalette db32 = NamedPalette('DawnBringer 32', [
    0xFF000000, 0xFF222034, 0xFF45283C, 0xFF663931, //
    0xFF8F563B, 0xFFDF7126, 0xFFD9A066, 0xFFEEC39A,
    0xFFFBF236, 0xFF99E550, 0xFF6ABE30, 0xFF37946E,
    0xFF4B692F, 0xFF524B24, 0xFF323C39, 0xFF3F3F74,
    0xFF306082, 0xFF5B6EE1, 0xFF639BFF, 0xFF5FCDE4,
    0xFFCBDBFC, 0xFFFFFFFF, 0xFF9BADB7, 0xFF847E87,
    0xFF696A6A, 0xFF595652, 0xFF76428A, 0xFFAC3232,
    0xFFD95763, 0xFFD77BBA, 0xFF8F974A, 0xFF8A6F30,
  ]);

  static const NamedPalette endesga32 = NamedPalette('Endesga 32', [
    0xFFBE4A2F, 0xFFD77643, 0xFFEAD4AA, 0xFFE4A672, //
    0xFFB86F50, 0xFF733E39, 0xFF3E2731, 0xFFA22633,
    0xFFE43B44, 0xFFF77622, 0xFFFEAE34, 0xFFFEE761,
    0xFF63C74D, 0xFF3E8948, 0xFF265C42, 0xFF193C3E,
    0xFF124E89, 0xFF0099DB, 0xFF2CE8F5, 0xFFFFFFFF,
    0xFFC0CBDC, 0xFF8B9BB4, 0xFF5A6988, 0xFF3A4466,
    0xFF262B44, 0xFF181425, 0xFFFF0044, 0xFF68386C,
    0xFFB55088, 0xFFF6757A, 0xFFE8B796, 0xFFC28569,
  ]);

  static const NamedPalette gameboy = NamedPalette('Game Boy', [
    0xFF0F380F, 0xFF306230, 0xFF8BAC0F, 0xFF9BBC0F, //
  ]);

  static const List<NamedPalette> presets = [
    db32,
    endesga32,
    pico8,
    sweetie16,
    db16,
    gameboy,
  ];

  /// Reads a palette file by what is in it: GIMP `.gpl`, JASC `.pal`, or a
  /// `.hex` list (one `RRGGBB` per line — Lospec's download). Colours are
  /// kept in file order, without repeats. Empty when nothing parses.
  static List<int> parse(String text) {
    final lines = text.split(RegExp(r'\r?\n')).map((l) => l.trim()).toList();
    final first = lines.isEmpty ? '' : lines.first;
    final out = <int>[];
    void add(int c) {
      if (!out.contains(c)) out.add(c);
    }

    final isGpl = first.toUpperCase().startsWith('GIMP PALETTE');
    final isJasc = first.toUpperCase() == 'JASC-PAL';
    if (isGpl || isJasc) {
      // JASC: header, version, count, then triples. GPL: header, optional
      // `Name:` / `Columns:` lines and `#` comments, then triples + a name.
      final triple = RegExp(r'^(\d{1,3})\s+(\d{1,3})\s+(\d{1,3})(?:\s|$)');
      for (final line in lines.skip(isJasc ? 3 : 1)) {
        final m = triple.firstMatch(line);
        if (m == null) continue;
        final r = int.parse(m[1]!), g = int.parse(m[2]!), b = int.parse(m[3]!);
        if (r > 255 || g > 255 || b > 255) continue;
        add(Argb.from(255, r, g, b));
      }
      return out;
    }
    for (final line in lines) {
      if (line.isEmpty || line.startsWith(';') || line.startsWith('//')) {
        continue;
      }
      final c = Argb.parseHex(line);
      if (c != null) add(c);
    }
    return out;
  }

  /// GIMP's format: the one most tools read.
  static String toGpl(String name, List<int> colors) {
    final b = StringBuffer('GIMP Palette\nName: $name\nColumns: 8\n#\n');
    for (final c in colors) {
      final r = Argb.red(c).toString().padLeft(3);
      final g = Argb.green(c).toString().padLeft(3);
      final bl = Argb.blue(c).toString().padLeft(3);
      b.writeln('$r $g $bl\t${Argb.toHex(c)}');
    }
    return b.toString();
  }

  /// Every distinct opaque-ish colour in [doc]'s cels, most used first:
  /// "palette from sprite".
  static List<int> fromPixels(Iterable<PixelBuffer> cels, {int limit = 256}) {
    final counts = <int, int>{};
    for (final cel in cels) {
      for (final p in cel.pixels) {
        if (p >> 24 == 0) continue;
        counts[p] = (counts[p] ?? 0) + 1;
      }
    }
    final sorted = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return sorted.take(limit).toList();
  }
}
