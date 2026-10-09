/// Pixel-exact drawing: every shape is a list of points, so symmetry, brush
/// size and preview are all the same few lines whatever the tool.
library;

import 'dart:typed_data';

import 'pixel_buffer.dart';

typedef Pixel = ({int x, int y});

/// Which axes a stroke is mirrored across.
enum Symmetry { none, horizontal, vertical, both }

abstract final class Raster {
  /// Bresenham: every pixel from ([x0],[y0]) to ([x1],[y1]), ends included.
  static List<Pixel> line(int x0, int y0, int x1, int y1) {
    final out = <Pixel>[];
    final dx = (x1 - x0).abs(), dy = -(y1 - y0).abs();
    final sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    var err = dx + dy, x = x0, y = y0;
    while (true) {
      out.add((x: x, y: y));
      if (x == x1 && y == y1) break;
      final e2 = 2 * err;
      if (e2 >= dy) {
        err += dy;
        x += sx;
      }
      if (e2 <= dx) {
        err += dx;
        y += sy;
      }
    }
    return out;
  }

  /// A freehand path with its corners cleaned: wherever three points in a
  /// row make an L — the middle one touching both neighbours by an edge
  /// while they touch each other by a corner — the middle one goes, so a
  /// one-pixel line stays one pixel wide on a diagonal.
  static List<Pixel> pixelPerfect(List<Pixel> path) {
    if (path.length < 3) return List.of(path);
    final out = <Pixel>[path.first];
    var i = 1;
    while (i < path.length - 1) {
      final a = out.last, b = path[i], c = path[i + 1];
      final isCorner =
          (a.x == b.x || a.y == b.y) &&
          (c.x == b.x || c.y == b.y) &&
          a.x != c.x &&
          a.y != c.y &&
          (a.x - c.x).abs() == 1 &&
          (a.y - c.y).abs() == 1;
      if (!isCorner) out.add(b);
      i++;
    }
    out.add(path.last);
    return out;
  }

  /// The pixels a round brush of [size] covers when centred on (0,0). Sizes
  /// 1–2 are squares; above that, a disc. Even sizes sit up-left of centre,
  /// as they do in Aseprite.
  static List<Pixel> brush(int size) {
    if (size <= 1) return const [(x: 0, y: 0)];
    final out = <Pixel>[];
    final lo = -(size ~/ 2), hi = lo + size - 1;
    final c = (lo + hi) / 2, r = size / 2;
    for (var y = lo; y <= hi; y++) {
      for (var x = lo; x <= hi; x++) {
        final ddx = x - c, ddy = y - c;
        if (size <= 2 || ddx * ddx + ddy * ddy <= r * r) out.add((x: x, y: y));
      }
    }
    return out;
  }

  /// Outline (or filled) rectangle between two corners, both inclusive.
  static List<Pixel> rectangle(
    int x0,
    int y0,
    int x1,
    int y1, {
    bool filled = false,
  }) {
    final r = IntRect.fromPoints(x0, y0, x1, y1);
    final out = <Pixel>[];
    for (var y = r.top; y < r.bottom; y++) {
      for (var x = r.left; x < r.right; x++) {
        final onEdge =
            x == r.left || x == r.right - 1 || y == r.top || y == r.bottom - 1;
        if (filled || onEdge) out.add((x: x, y: y));
      }
    }
    return out;
  }

  /// Ellipse inscribed in the box between two corners, both inclusive.
  /// Handles boxes of even size, which a centre-and-radius ellipse cannot.
  static List<Pixel> ellipse(
    int x0,
    int y0,
    int x1,
    int y1, {
    bool filled = false,
  }) {
    final r = IntRect.fromPoints(x0, y0, x1, y1);
    final w = r.width, h = r.height;
    if (w <= 2 || h <= 2) return rectangle(x0, y0, x1, y1, filled: true);
    final cx = (r.left + r.right - 1) / 2, cy = (r.top + r.bottom - 1) / 2;
    final rx = w / 2, ry = h / 2;
    bool inside(int x, int y) {
      final nx = (x - cx) / rx, ny = (y - cy) / ry;
      return nx * nx + ny * ny <= 1.0;
    }

    final out = <Pixel>[];
    for (var y = r.top; y < r.bottom; y++) {
      for (var x = r.left; x < r.right; x++) {
        if (!inside(x, y)) continue;
        if (filled ||
            !inside(x - 1, y) ||
            !inside(x + 1, y) ||
            !inside(x, y - 1) ||
            !inside(x, y + 1)) {
          out.add((x: x, y: y));
        }
      }
    }
    return out;
  }

  /// [points] plus their mirror images on a [width] × [height] canvas.
  static List<Pixel> mirrored(
    List<Pixel> points,
    Symmetry symmetry,
    int width,
    int height,
  ) {
    if (symmetry == Symmetry.none) return points;
    final h = symmetry == Symmetry.horizontal || symmetry == Symmetry.both;
    final v = symmetry == Symmetry.vertical || symmetry == Symmetry.both;
    return [
      ...points,
      if (h)
        for (final p in points) (x: width - 1 - p.x, y: p.y),
      if (v)
        for (final p in points) (x: p.x, y: height - 1 - p.y),
      if (h && v)
        for (final p in points) (x: width - 1 - p.x, y: height - 1 - p.y),
    ];
  }

  /// Stamps [brushShape] at every one of [points] in [color]. With [mask],
  /// only pixels inside the selection change. [erase] sets transparent.
  static void stamp(
    PixelBuffer target,
    List<Pixel> points,
    List<Pixel> brushShape,
    int color, {
    SelectionMask? mask,
  }) {
    for (final p in points) {
      for (final b in brushShape) {
        final x = p.x + b.x, y = p.y + b.y;
        if (mask != null && !mask.contains(x, y)) continue;
        target.set(x, y, color);
      }
    }
  }

  /// Flood fill from ([x],[y]) with [color]. [contiguous] fills the touching
  /// region of the start pixel's colour; otherwise every pixel of that
  /// colour. Returns how many pixels changed.
  static int fill(
    PixelBuffer target,
    int x,
    int y,
    int color, {
    bool contiguous = true,
    SelectionMask? mask,
  }) {
    if (!target.inside(x, y)) return 0;
    if (mask != null && !mask.contains(x, y)) return 0;
    final w = target.width, h = target.height, px = target.pixels;
    final from = px[y * w + x];
    if (_same(from, color)) return 0;
    var changed = 0;
    bool open(int i, int xx, int yy) =>
        _same(px[i], from) && (mask == null || mask.contains(xx, yy));

    if (!contiguous) {
      for (var yy = 0; yy < h; yy++) {
        for (var xx = 0; xx < w; xx++) {
          final i = yy * w + xx;
          if (open(i, xx, yy)) {
            px[i] = color;
            changed++;
          }
        }
      }
      return changed;
    }

    // Scanline fill: a stack of seeds, each widened into a run.
    final stack = <int>[x, y];
    while (stack.isNotEmpty) {
      final sy = stack.removeLast();
      var sx = stack.removeLast();
      if (!open(sy * w + sx, sx, sy)) continue;
      while (sx > 0 && open(sy * w + sx - 1, sx - 1, sy)) {
        sx--;
      }
      var above = false, below = false;
      for (var xx = sx; xx < w && open(sy * w + xx, xx, sy); xx++) {
        px[sy * w + xx] = color;
        changed++;
        if (sy > 0) {
          final o = open((sy - 1) * w + xx, xx, sy - 1);
          if (o && !above) {
            stack
              ..add(xx)
              ..add(sy - 1);
          }
          above = o;
        }
        if (sy < h - 1) {
          final o = open((sy + 1) * w + xx, xx, sy + 1);
          if (o && !below) {
            stack
              ..add(xx)
              ..add(sy + 1);
          }
          below = o;
        }
      }
    }
    return changed;
  }

  /// Two colours are the same pixel if equal, or both fully transparent —
  /// whatever RGB hides under zero alpha.
  static bool _same(int a, int b) => a == b || (a >> 24 == 0 && b >> 24 == 0);

  /// Every pixel of colour [from] becomes [to]. Returns how many changed.
  static int replaceColor(
    PixelBuffer target,
    int from,
    int to, {
    SelectionMask? mask,
  }) {
    var changed = 0;
    final w = target.width;
    for (var i = 0; i < target.pixels.length; i++) {
      if (!_same(target.pixels[i], from)) continue;
      if (mask != null && !mask.contains(i % w, i ~/ w)) continue;
      target.pixels[i] = to;
      changed++;
    }
    return changed;
  }
}

/// Which pixels of the canvas are selected.
class SelectionMask {
  SelectionMask(this.width, this.height) : _bits = Uint8List(width * height);

  /// A rectangle, clipped to the canvas.
  factory SelectionMask.rect(int width, int height, IntRect rect) {
    final mask = SelectionMask(width, height);
    final r = rect.intersect(IntRect(0, 0, width, height));
    for (var y = r.top; y < r.bottom; y++) {
      mask._bits.fillRange(y * width + r.left, y * width + r.right, 1);
    }
    return mask;
  }

  final int width;
  final int height;
  final Uint8List _bits;

  bool contains(int x, int y) =>
      x >= 0 && y >= 0 && x < width && y < height && _bits[y * width + x] != 0;

  void set(int x, int y, bool selected) {
    if (x >= 0 && y >= 0 && x < width && y < height) {
      _bits[y * width + x] = selected ? 1 : 0;
    }
  }

  bool get isEmpty => !_bits.any((b) => b != 0);

  IntRect get bounds {
    var minX = width, minY = height, maxX = -1, maxY = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (_bits[y * width + x] == 0) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    return maxX < 0 ? IntRect.empty : IntRect(minX, minY, maxX + 1, maxY + 1);
  }

  /// The selected pixels of [source] as a buffer the size of [bounds], the
  /// rest transparent.
  PixelBuffer lift(PixelBuffer source) {
    final b = bounds;
    final out = PixelBuffer(b.width, b.height);
    for (var y = b.top; y < b.bottom; y++) {
      for (var x = b.left; x < b.right; x++) {
        if (contains(x, y)) out.set(x - b.left, y - b.top, source.get(x, y));
      }
    }
    return out;
  }

  /// Makes the selected pixels of [target] transparent.
  void clearIn(PixelBuffer target) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (_bits[y * width + x] != 0) target.set(x, y, Argb.transparent);
      }
    }
  }

  SelectionMask translated(int dx, int dy) {
    final out = SelectionMask(width, height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (_bits[y * width + x] != 0) out.set(x + dx, y + dy, true);
      }
    }
    return out;
  }
}
