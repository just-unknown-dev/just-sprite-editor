import '../document/document_editor.dart';
import '../document/pixel_buffer.dart';
import '../document/raster.dart';
import 'studio_session.dart';

/// Which mouse button a gesture began with: the primary colour, or the
/// secondary one.
enum ToolButton { primary, secondary }

/// A drawing tool: told where the pointer is, in sprite pixels. One class
/// per tool, each behind this interface, so adding one is adding a class
/// and an entry in [PixelTools.of].
abstract class PixelTool {
  /// The pointer went down on pixel ([x], [y]).
  void down(SpriteStudioSession s, int x, int y, ToolButton button);

  /// The pointer moved to ([x], [y]) while down.
  void drag(SpriteStudioSession s, int x, int y) {}

  /// The pointer came up.
  void up(SpriteStudioSession s) {}

  /// The gesture was abandoned (Esc, a lost pointer): leave no trace.
  void cancel(SpriteStudioSession s) {}
}

abstract final class PixelTools {
  static PixelTool of(StudioTool tool) => switch (tool) {
    StudioTool.pencil => FreehandTool(erase: false),
    StudioTool.eraser => FreehandTool(erase: true),
    StudioTool.fill => FillTool(),
    StudioTool.picker => PickerTool(),
    StudioTool.line => ShapeTool(ShapeKind.line),
    StudioTool.rectangle => ShapeTool(ShapeKind.rectangle),
    StudioTool.ellipse => ShapeTool(ShapeKind.ellipse),
    StudioTool.select => SelectTool(),
    StudioTool.move => MoveTool(),
  };
}

int _colorFor(SpriteStudioSession s, ToolButton button, {bool erase = false}) {
  if (erase) return Argb.transparent;
  return button == ToolButton.primary ? s.primary.value : s.secondary.value;
}

/// Stamps [points] with the session's brush, mirrored as it is set, into
/// [target] (inside the selection, if there is one). Returns the
/// rectangle that may have changed, for the next [CelStroke.reset].
IntRect _paint(
  SpriteStudioSession s,
  PixelBuffer target,
  List<Pixel> points,
  int color,
) {
  final doc = s.document;
  // The brush is applied before mirroring, not after: an even-sized brush
  // sits off-centre, and its mirror image has to sit off-centre the other
  // way.
  final brush = Raster.brush(s.brushSize.value);
  final covered = brush.length == 1
      ? points
      : [
          for (final p in points)
            for (final b in brush) (x: p.x + b.x, y: p.y + b.y),
        ];
  final all = Raster.mirrored(covered, s.symmetry.value, doc.width, doc.height);
  Raster.stamp(
    target,
    all,
    const [(x: 0, y: 0)],
    color,
    mask: s.selection.value,
  );
  return _boundsOf(all);
}

IntRect _boundsOf(List<Pixel> points) {
  if (points.isEmpty) return IntRect.empty;
  var minX = points.first.x, maxX = minX;
  var minY = points.first.y, maxY = minY;
  for (final p in points) {
    if (p.x < minX) minX = p.x;
    if (p.x > maxX) maxX = p.x;
    if (p.y < minY) minY = p.y;
    if (p.y > maxY) maxY = p.y;
  }
  return IntRect(minX, minY, maxX + 1, maxY + 1);
}

/// Pencil and eraser: a path of pixels, stamped with the brush.
///
/// Each move stamps only the pixels it adds. Pixel-perfect cleaning (a
/// one-pixel brush) can take back a point already laid down — the corner
/// of an L the new point makes — so every canvas pixel the stroke covers
/// counts the stamps on it, and goes back to what it was only when the
/// last of them is gone. The result is the same as stamping the whole
/// cleaned path at once.
class FreehandTool extends PixelTool {
  FreehandTool({required this.erase});

  final bool erase;
  CelStroke? _stroke;
  Pixel _last = (x: 0, y: 0);
  int _color = 0;

  // Fixed for the stroke when it begins.
  List<Pixel> _brush = const [(x: 0, y: 0)];
  Symmetry _symmetry = Symmetry.none;
  SelectionMask? _mask;
  PixelPerfectPath? _clean;

  /// Stamps on each covered pixel, by its index in the cel.
  final Map<int, int> _stamps = {};

  @override
  void down(SpriteStudioSession s, int x, int y, ToolButton button) {
    _stroke = s.beginStroke(erase ? 'Eraser' : 'Pencil');
    if (_stroke == null) return;
    _color = _colorFor(s, button, erase: erase);
    _brush = Raster.brush(s.brushSize.value);
    _symmetry = s.symmetry.value;
    _mask = s.selection.value;
    _clean = s.pixelPerfect.value && s.brushSize.value == 1
        ? PixelPerfectPath()
        : null;
    _stamps.clear();
    _last = (x: x, y: y);
    _add(_last);
    _changed(s);
  }

  @override
  void drag(SpriteStudioSession s, int x, int y) {
    final stroke = _stroke;
    if (stroke == null || stroke.isDone) return;
    if (_last.x == x && _last.y == y) return;
    // A fast pointer skips pixels; join the dots.
    for (final p in Raster.line(_last.x, _last.y, x, y).skip(1)) {
      _add(p);
    }
    _last = (x: x, y: y);
    _changed(s);
  }

  void _add(Pixel p) {
    final corner = _clean?.add(p);
    if (corner != null) _stamp(corner, -1);
    _stamp(p, 1);
  }

  /// Lays the brush down at [p] ([delta] 1), or takes one such stamp back
  /// ([delta] -1).
  void _stamp(Pixel p, int delta) {
    final stroke = _stroke!;
    final target = stroke.buffer, before = stroke.original;
    final w = target.width, h = target.height;
    final mask = _mask;
    final covered = _brush.length == 1
        ? [p]
        : [for (final b in _brush) (x: p.x + b.x, y: p.y + b.y)];
    for (final t in Raster.mirrored(covered, _symmetry, w, h)) {
      if (t.x < 0 || t.y < 0 || t.x >= w || t.y >= h) continue;
      if (mask != null && !mask.contains(t.x, t.y)) continue;
      final i = t.y * w + t.x;
      final n = (_stamps[i] ?? 0) + delta;
      if (n > 0) {
        _stamps[i] = n;
        target.pixels[i] = _color;
      } else {
        _stamps.remove(i);
        target.pixels[i] = before.pixels[i];
      }
    }
  }

  void _changed(SpriteStudioSession s) {
    s.document.touch();
    s.changed();
  }

  @override
  void up(SpriteStudioSession s) {
    _stroke?.commit();
    _stroke = null;
    s.changed();
  }

  @override
  void cancel(SpriteStudioSession s) {
    _stroke?.cancel();
    _stroke = null;
    s.changed();
  }
}

class FillTool extends PixelTool {
  @override
  void down(SpriteStudioSession s, int x, int y, ToolButton button) {
    final stroke = s.beginStroke('Fill');
    if (stroke == null) return;
    Raster.fill(
      stroke.buffer,
      x,
      y,
      _colorFor(s, button),
      contiguous: s.contiguousFill.value,
      mask: s.selection.value,
    );
    stroke.commit();
    s.changed();
  }
}

/// Takes the colour under the pointer — from the picture, not just the
/// active layer, because that is what the eye is pointing at.
class PickerTool extends PixelTool {
  ToolButton _button = ToolButton.primary;

  @override
  void down(SpriteStudioSession s, int x, int y, ToolButton button) {
    _button = button;
    drag(s, x, y);
  }

  @override
  void drag(SpriteStudioSession s, int x, int y) {
    // The one pixel through every visible layer, rather than the whole
    // frame drawn on every move to read it.
    final color = s.document.pixelAt(s.frameIndex.value, x, y);
    if (Argb.alpha(color) == 0) return;
    (_button == ToolButton.primary ? s.primary : s.secondary).value = color;
  }
}

enum ShapeKind { line, rectangle, ellipse }

/// Line, rectangle, ellipse: redrawn from the start point as the pointer
/// moves, committed on release.
class ShapeTool extends PixelTool {
  ShapeTool(this.kind);

  final ShapeKind kind;
  CelStroke? _stroke;
  int _x0 = 0, _y0 = 0, _color = 0;

  /// Where the shape was last drawn: all a redraw has to put back.
  IntRect _drawn = IntRect.empty;

  @override
  void down(SpriteStudioSession s, int x, int y, ToolButton button) {
    _stroke = s.beginStroke(switch (kind) {
      ShapeKind.line => 'Line',
      ShapeKind.rectangle => 'Rectangle',
      ShapeKind.ellipse => 'Ellipse',
    });
    if (_stroke == null) return;
    _x0 = x;
    _y0 = y;
    _color = _colorFor(s, button);
    _drawn = IntRect.empty;
    drag(s, x, y);
  }

  @override
  void drag(SpriteStudioSession s, int x, int y) {
    final stroke = _stroke;
    if (stroke == null || stroke.isDone) return;
    if (!_drawn.isEmpty) stroke.reset(_drawn);
    final filled = s.filledShapes.value;
    final points = switch (kind) {
      ShapeKind.line => Raster.line(_x0, _y0, x, y),
      ShapeKind.rectangle => Raster.rectangle(_x0, _y0, x, y, filled: filled),
      ShapeKind.ellipse => Raster.ellipse(_x0, _y0, x, y, filled: filled),
    };
    _drawn = _paint(s, stroke.buffer, points, _color);
    s.document.touch();
    s.changed();
  }

  @override
  void up(SpriteStudioSession s) {
    _stroke?.commit();
    _stroke = null;
    s.changed();
  }

  @override
  void cancel(SpriteStudioSession s) {
    _stroke?.cancel();
    _stroke = null;
    s.changed();
  }
}

/// Rectangular selection. A click without a drag clears it.
class SelectTool extends PixelTool {
  int _x0 = 0, _y0 = 0;
  bool _dragged = false;

  @override
  void down(SpriteStudioSession s, int x, int y, ToolButton button) {
    _x0 = x;
    _y0 = y;
    _dragged = false;
  }

  @override
  void drag(SpriteStudioSession s, int x, int y) {
    if (x == _x0 && y == _y0 && !_dragged) return;
    _dragged = true;
    final doc = s.document;
    s.selection.value = SelectionMask.rect(
      doc.width,
      doc.height,
      IntRect.fromPoints(_x0, _y0, x, y),
    );
  }

  @override
  void up(SpriteStudioSession s) {
    if (!_dragged) s.selection.value = null;
  }
}

/// Moves the selected pixels — or the whole cel when nothing is selected.
class MoveTool extends PixelTool {
  CelStroke? _stroke;
  PixelBuffer? _lifted;
  SelectionMask? _mask;
  IntRect _from = IntRect.empty;
  int _x0 = 0, _y0 = 0;

  /// Where the lifted pixels were last put down.
  IntRect _placed = IntRect.empty;

  @override
  void down(SpriteStudioSession s, int x, int y, ToolButton button) {
    _stroke = s.beginStroke('Move');
    final stroke = _stroke;
    if (stroke == null) return;
    final doc = s.document;
    _mask =
        s.selection.value ??
        SelectionMask.rect(doc.width, doc.height, doc.bounds);
    _from = _mask!.bounds;
    _placed = _from;
    _lifted = _mask!.lift(stroke.original);
    _x0 = x;
    _y0 = y;
  }

  @override
  void drag(SpriteStudioSession s, int x, int y) {
    final stroke = _stroke;
    if (stroke == null || stroke.isDone) return;
    final dx = x - _x0, dy = y - _y0;
    // Only what the last move touched goes back: where the pixels came
    // from, and where they were put down.
    stroke.reset(_from.union(_placed));
    _mask!.clearIn(stroke.buffer);
    _placed = _from.translate(dx, dy);
    stroke.buffer.composite(_lifted!, _placed.left, _placed.top);
    if (s.selection.value != null) {
      s.selection.value = _mask!.translated(dx, dy);
    }
    s.document.touch();
    s.changed();
  }

  @override
  void up(SpriteStudioSession s) {
    _stroke?.commit();
    _stroke = null;
    s.changed();
  }

  @override
  void cancel(SpriteStudioSession s) {
    _stroke?.cancel();
    _stroke = null;
    if (s.selection.value != null) s.selection.value = _mask;
    s.changed();
  }
}

// Edits that are not gestures: the Edit menu.
abstract final class StudioActions {
  /// Clears the selection's pixels (or the whole cel) on the active layer.
  static void deletePixels(SpriteStudioSession s) {
    final stroke = s.beginStroke('Delete');
    if (stroke == null) return;
    final mask = s.selection.value;
    if (mask == null) {
      stroke.buffer.clear();
    } else {
      mask.clearIn(stroke.buffer);
    }
    stroke.commit();
    s.changed();
  }

  /// Flips the selected pixels, or the active cel.
  static void flip(SpriteStudioSession s, {required bool horizontal}) {
    final stroke = s.beginStroke(
      horizontal ? 'Flip horizontal' : 'Flip vertical',
    );
    if (stroke == null) return;
    final doc = s.document;
    final mask =
        s.selection.value ??
        SelectionMask.rect(doc.width, doc.height, doc.bounds);
    final at = mask.bounds;
    final lifted = mask.lift(stroke.original);
    mask.clearIn(stroke.buffer);
    stroke.buffer.composite(
      horizontal ? lifted.flippedHorizontally() : lifted.flippedVertically(),
      at.left,
      at.top,
    );
    stroke.commit();
    s.changed();
  }

  /// A quarter turn of the selected pixels (or the cel) about their middle.
  static void rotate(SpriteStudioSession s, {bool clockwise = true}) {
    final stroke = s.beginStroke('Rotate 90°');
    if (stroke == null) return;
    final doc = s.document;
    final mask =
        s.selection.value ??
        SelectionMask.rect(doc.width, doc.height, doc.bounds);
    final at = mask.bounds;
    final turned = mask.lift(stroke.original).rotated90(clockwise: clockwise);
    mask.clearIn(stroke.buffer);
    final x = at.left + (at.width - turned.width) ~/ 2;
    final y = at.top + (at.height - turned.height) ~/ 2;
    stroke.buffer.composite(turned, x, y);
    stroke.commit();
    if (s.selection.value != null) {
      s.selection.value = SelectionMask.rect(
        doc.width,
        doc.height,
        IntRect.fromLTWH(x, y, turned.width, turned.height),
      );
    }
    s.changed();
  }

  /// Every pixel of the primary colour on the active cel becomes the
  /// secondary one.
  static void replaceColor(SpriteStudioSession s) {
    final stroke = s.beginStroke('Replace colour');
    if (stroke == null) return;
    final n = Raster.replaceColor(
      stroke.buffer,
      s.primary.value,
      s.secondary.value,
      mask: s.selection.value,
    );
    stroke.commit();
    s
      ..changed()
      ..say(n == 0 ? 'No pixels of that colour here.' : 'Replaced $n pixels.');
  }

  static void selectAll(SpriteStudioSession s) {
    final doc = s.document;
    s.selection.value = SelectionMask.rect(doc.width, doc.height, doc.bounds);
  }

  static void cropToSelection(SpriteStudioSession s) {
    final mask = s.selection.value;
    if (mask == null || mask.isEmpty) {
      return s.say('Select an area to crop to.');
    }
    final to = mask.bounds;
    s
      ..selection.value = null
      ..structural('Crop', (d) => d.cropTo(to));
  }
}
