import 'dart:typed_data';

/// An integer rectangle: left/top inclusive, right/bottom exclusive.
class IntRect {
  const IntRect(this.left, this.top, this.right, this.bottom);

  const IntRect.fromLTWH(int left, int top, int width, int height)
    : this(left, top, left + width, top + height);

  /// From two corners in any order, both inclusive.
  factory IntRect.fromPoints(int x0, int y0, int x1, int y1) => IntRect(
    x0 < x1 ? x0 : x1,
    y0 < y1 ? y0 : y1,
    (x0 > x1 ? x0 : x1) + 1,
    (y0 > y1 ? y0 : y1) + 1,
  );

  static const IntRect empty = IntRect(0, 0, 0, 0);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;
  bool get isEmpty => right <= left || bottom <= top;

  bool contains(int x, int y) =>
      x >= left && x < right && y >= top && y < bottom;

  IntRect intersect(IntRect o) {
    final l = left > o.left ? left : o.left;
    final t = top > o.top ? top : o.top;
    final r = right < o.right ? right : o.right;
    final b = bottom < o.bottom ? bottom : o.bottom;
    return r <= l || b <= t ? empty : IntRect(l, t, r, b);
  }

  /// The smallest rectangle holding both; an empty one does not count.
  IntRect union(IntRect o) {
    if (isEmpty) return o;
    if (o.isEmpty) return this;
    return IntRect(
      left < o.left ? left : o.left,
      top < o.top ? top : o.top,
      right > o.right ? right : o.right,
      bottom > o.bottom ? bottom : o.bottom,
    );
  }

  IntRect translate(int dx, int dy) =>
      IntRect(left + dx, top + dy, right + dx, bottom + dy);

  @override
  bool operator ==(Object other) =>
      other is IntRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'IntRect($left, $top, $right, $bottom)';
}

/// Colours as `0xAARRGGBB` ints with straight (not premultiplied) alpha —
/// the same layout as Flutter's `Color.value`.
abstract final class Argb {
  static const int transparent = 0x00000000;

  static int alpha(int c) => (c >> 24) & 0xFF;
  static int red(int c) => (c >> 16) & 0xFF;
  static int green(int c) => (c >> 8) & 0xFF;
  static int blue(int c) => c & 0xFF;

  static int from(int a, int r, int g, int b) =>
      ((a & 0xFF) << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);

  /// [src] over [dst], with [opacity] (0–255) scaling the source's alpha.
  static int over(int dst, int src, [int opacity = 255]) {
    var sa = alpha(src);
    if (opacity < 255) sa = (sa * opacity + 127) ~/ 255;
    if (sa == 0) return dst;
    final da = alpha(dst);
    if (sa == 255 || da == 0) return (src & 0x00FFFFFF) | (sa << 24);
    // Straight-alpha "over": out = src·sa + dst·da·(1 − sa), divided by the
    // resulting alpha.
    final inv = 255 - sa;
    final outA = sa + (da * inv + 127) ~/ 255;
    if (outA == 0) return transparent;
    int mix(int s, int d) =>
        ((s * sa * 255 + d * da * inv) + (outA * 255) ~/ 2) ~/ (outA * 255);
    return from(
      outA,
      mix(red(src), red(dst)),
      mix(green(src), green(dst)),
      mix(blue(src), blue(dst)),
    );
  }

  /// `#RRGGBB` or `#AARRGGBB`.
  static String toHex(int c) {
    final a = alpha(c);
    final rgb = (c & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return a == 255
        ? '#$rgb'.toUpperCase()
        : '#${a.toRadixString(16).padLeft(2, '0')}$rgb'.toUpperCase();
  }

  /// Parses `RRGGBB`, `AARRGGBB`, with or without `#`. Null when it is not
  /// one.
  static int? parseHex(String text) {
    var t = text.trim();
    if (t.startsWith('#')) t = t.substring(1);
    if (t.length == 3) t = t.split('').map((ch) => '$ch$ch').join();
    if (t.length != 6 && t.length != 8) return null;
    final v = int.tryParse(t, radix: 16);
    if (v == null) return null;
    return t.length == 6 ? 0xFF000000 | v : v;
  }
}

/// A rectangle of pixels. Reads outside it give transparent; writes outside
/// it are ignored — so a tool never has to clip.
class PixelBuffer {
  PixelBuffer(this.width, this.height)
    : assert(width >= 0 && height >= 0),
      pixels = Uint32List(width * height);

  PixelBuffer.of(this.width, this.height, this.pixels)
    : assert(pixels.length == width * height);

  final int width;
  final int height;

  /// Row-major `0xAARRGGBB`.
  final Uint32List pixels;

  IntRect get bounds => IntRect(0, 0, width, height);

  bool inside(int x, int y) => x >= 0 && y >= 0 && x < width && y < height;

  int get(int x, int y) => inside(x, y) ? pixels[y * width + x] : 0;

  void set(int x, int y, int color) {
    if (inside(x, y)) pixels[y * width + x] = color;
  }

  void fill(int color) => pixels.fillRange(0, pixels.length, color);

  void clear() => fill(Argb.transparent);

  bool get isBlank {
    for (final p in pixels) {
      if (Argb.alpha(p) != 0) return false;
    }
    return true;
  }

  PixelBuffer copy() =>
      PixelBuffer.of(width, height, Uint32List.fromList(pixels));

  /// The pixels of [rect] (clipped to this buffer) as a new buffer the size
  /// of the clipped rectangle.
  PixelBuffer copyRect(IntRect rect) {
    final r = rect.intersect(bounds);
    final out = PixelBuffer(r.width, r.height);
    for (var y = 0; y < r.height; y++) {
      final from = (r.top + y) * width + r.left;
      out.pixels.setRange(y * r.width, (y + 1) * r.width, pixels, from);
    }
    return out;
  }

  /// Writes [src] with its corner at ([dx], [dy]), replacing what is there —
  /// transparent included.
  void paste(PixelBuffer src, int dx, int dy) {
    final r = IntRect.fromLTWH(dx, dy, src.width, src.height).intersect(bounds);
    for (var y = r.top; y < r.bottom; y++) {
      final sy = y - dy;
      final from = sy * src.width + (r.left - dx);
      pixels.setRange(
        y * width + r.left,
        y * width + r.right,
        src.pixels,
        from,
      );
    }
  }

  /// Draws [src] over this with its corner at ([dx], [dy]), blending by
  /// alpha, with [opacity] 0–255 on top.
  void composite(PixelBuffer src, int dx, int dy, {int opacity = 255}) {
    if (opacity <= 0) return;
    final r = IntRect.fromLTWH(dx, dy, src.width, src.height).intersect(bounds);
    for (var y = r.top; y < r.bottom; y++) {
      var si = (y - dy) * src.width + (r.left - dx);
      var di = y * width + r.left;
      for (var x = r.left; x < r.right; x++, si++, di++) {
        final s = src.pixels[si];
        if (s >> 24 != 0) pixels[di] = Argb.over(pixels[di], s, opacity);
      }
    }
  }

  /// The smallest rectangle holding every pixel that is not fully
  /// transparent; [IntRect.empty] for a blank buffer.
  IntRect get contentBounds {
    var minX = width, minY = height, maxX = -1, maxY = -1;
    for (var y = 0; y < height; y++) {
      final row = y * width;
      for (var x = 0; x < width; x++) {
        if (pixels[row + x] >> 24 == 0) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    return maxX < 0 ? IntRect.empty : IntRect(minX, minY, maxX + 1, maxY + 1);
  }

  PixelBuffer flippedHorizontally() {
    final out = PixelBuffer(width, height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        out.pixels[y * width + (width - 1 - x)] = pixels[y * width + x];
      }
    }
    return out;
  }

  PixelBuffer flippedVertically() {
    final out = PixelBuffer(width, height);
    for (var y = 0; y < height; y++) {
      out.pixels.setRange(
        (height - 1 - y) * width,
        (height - y) * width,
        pixels,
        y * width,
      );
    }
    return out;
  }

  /// A quarter turn; the result is [height] wide and [width] tall.
  PixelBuffer rotated90({bool clockwise = true}) {
    final out = PixelBuffer(height, width);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final nx = clockwise ? height - 1 - y : y;
        final ny = clockwise ? x : width - 1 - x;
        out.pixels[ny * height + nx] = pixels[y * width + x];
      }
    }
    return out;
  }

  /// A copy of [newWidth] × [newHeight] with this content placed at
  /// ([dx], [dy]): a canvas resize, not a scale.
  PixelBuffer resizedCanvas(
    int newWidth,
    int newHeight, {
    int dx = 0,
    int dy = 0,
  }) => PixelBuffer(newWidth, newHeight)..paste(this, dx, dy);

  /// Scaled by whole-number [factor] with no smoothing.
  PixelBuffer scaledUp(int factor) {
    assert(factor >= 1);
    final out = PixelBuffer(width * factor, height * factor);
    for (var y = 0; y < out.height; y++) {
      final sy = (y ~/ factor) * width;
      final dy = y * out.width;
      for (var x = 0; x < out.width; x++) {
        out.pixels[dy + x] = pixels[sy + x ~/ factor];
      }
    }
    return out;
  }

  bool sameAs(PixelBuffer other) {
    if (other.width != width || other.height != height) return false;
    for (var i = 0; i < pixels.length; i++) {
      if (pixels[i] != other.pixels[i]) return false;
    }
    return true;
  }

  /// RGBA bytes, row-major — what image encoders and `dart:ui` take.
  Uint8List toRgbaBytes() {
    final out = Uint8List(pixels.length * 4);
    for (var i = 0, o = 0; i < pixels.length; i++, o += 4) {
      final c = pixels[i];
      out[o] = (c >> 16) & 0xFF;
      out[o + 1] = (c >> 8) & 0xFF;
      out[o + 2] = c & 0xFF;
      out[o + 3] = (c >> 24) & 0xFF;
    }
    return out;
  }

  /// From straight-alpha RGBA bytes.
  factory PixelBuffer.fromRgbaBytes(int width, int height, List<int> rgba) {
    final out = PixelBuffer(width, height);
    for (var i = 0, o = 0; i < out.pixels.length; i++, o += 4) {
      out.pixels[i] = Argb.from(rgba[o + 3], rgba[o], rgba[o + 1], rgba[o + 2]);
    }
    return out;
  }
}
