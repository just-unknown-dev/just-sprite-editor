import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_signals/just_signals.dart';

import '../document/pixel_buffer.dart';
import '../document/raster.dart';
import 'studio_session.dart';
import 'studio_theme.dart';
import 'studio_tools.dart';

/// Turns pixels into something the GPU can draw. The bytes are premultiplied
/// on the way, which is what the engine's raw RGBA upload expects.
Future<ui.Image> imageFromPixels(PixelBuffer buffer) {
  final bytes = Uint8List(buffer.pixels.length * 4);
  for (var i = 0, o = 0; i < buffer.pixels.length; i++, o += 4) {
    final c = buffer.pixels[i];
    final a = (c >> 24) & 0xFF;
    bytes[o] = (((c >> 16) & 0xFF) * a + 127) ~/ 255;
    bytes[o + 1] = (((c >> 8) & 0xFF) * a + 127) ~/ 255;
    bytes[o + 2] = ((c & 0xFF) * a + 127) ~/ 255;
    bytes[o + 3] = a;
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    buffer.width,
    buffer.height,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

/// Decodes an image file's bytes into straight-alpha pixels.
Future<PixelBuffer> pixelsFromImageBytes(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  final out = PixelBuffer.fromRgbaBytes(
    image.width,
    image.height,
    data!.buffer.asUint8List(),
  );
  image.dispose();
  return out;
}

/// The drawing surface: the sprite, zoomed, with the active tool under the
/// pointer.
class StudioCanvas extends StatefulWidget {
  const StudioCanvas({super.key, required this.session});

  final SpriteStudioSession session;

  @override
  State<StudioCanvas> createState() => StudioCanvasState();
}

class StudioCanvasState extends State<StudioCanvas> {
  SpriteStudioSession get s => widget.session;

  ui.Image? _image;
  final Map<int, ui.Image> _onion = {};
  int _wanted = 0;
  List<VoidCallback> _stop = const [];

  PixelTool? _tool;
  bool _panning = false;
  Offset? _hover;
  Size _viewSize = Size.zero;
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    _watch();
    _refresh();
  }

  @override
  void didUpdateWidget(StudioCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      for (final stop in _stop) {
        stop();
      }
      _fitted = false;
      _watch();
      _refresh();
    }
  }

  void _watch() {
    _stop = [
      s.revision.watch(_refresh),
      s.frameIndex.watch(_refresh),
      s.onionSkin.watch(_refresh),
    ];
  }

  @override
  void dispose() {
    for (final stop in _stop) {
      stop();
    }
    super.dispose();
  }

  /// Rebuilds the GPU images of the frame (and its onion neighbours). The
  /// old image keeps showing until the new one is ready, so nothing flashes.
  Future<void> _refresh() async {
    final ticket = ++_wanted;
    final doc = s.document;
    final at = s.frameIndex.value.clamp(0, doc.frames.length - 1);
    final onion = s.onionSkin.value;
    final neighbours = <int>[
      if (onion.enabled && !s.isPlaying.value) ...[
        for (var i = 1; i <= onion.before; i++)
          if (at - i >= 0) at - i,
        for (var i = 1; i <= onion.after; i++)
          if (at + i < doc.frames.length) at + i,
      ],
    ];
    final image = await imageFromPixels(doc.flatten(at));
    final skins = <int, ui.Image>{
      for (final i in neighbours) i - at: await imageFromPixels(doc.flatten(i)),
    };
    if (!mounted || ticket != _wanted) return;
    setState(() {
      _image = image;
      _onion
        ..clear()
        ..addAll(skins);
    });
  }

  // ── Geometry ─────────────────────────────────────────────────────────────

  /// Where the sprite's top-left corner is, in this widget.
  Offset get _origin {
    final z = s.zoom.value;
    return Offset(
          (_viewSize.width - s.document.width * z) / 2,
          (_viewSize.height - s.document.height * z) / 2,
        ) +
        s.pan.value;
  }

  /// The sprite pixel under [local].
  ({int x, int y}) pixelAt(Offset local) {
    final p = (local - _origin) / s.zoom.value;
    return (x: p.dx.floor(), y: p.dy.floor());
  }

  // ── Pointer ──────────────────────────────────────────────────────────────

  void _down(PointerDownEvent e) {
    if (e.buttons & kMiddleMouseButton != 0 ||
        HardwareKeyboard.instance.isLogicalKeyPressed(
          LogicalKeyboardKey.space,
        )) {
      _panning = true;
      return;
    }
    s.stop();
    final p = pixelAt(e.localPosition);
    // Alt makes any tool a colour picker for the moment, as artists expect.
    final tool = HardwareKeyboard.instance.isAltPressed
        ? StudioTool.picker
        : s.tool.value;
    _tool = PixelTools.of(tool)
      ..down(
        s,
        p.x,
        p.y,
        e.buttons & kSecondaryMouseButton != 0
            ? ToolButton.secondary
            : ToolButton.primary,
      );
  }

  void _move(PointerEvent e) {
    if (_panning) {
      s.pan.value += e.delta;
      return;
    }
    final p = pixelAt(e.localPosition);
    _tool?.drag(s, p.x, p.y);
    setState(() => _hover = e.localPosition);
  }

  void _up(PointerEvent e) {
    _panning = false;
    _tool?.up(s);
    _tool = null;
  }

  /// Abandons the gesture in progress. True if there was one.
  bool cancelGesture() {
    final tool = _tool;
    if (tool == null) return false;
    tool.cancel(s);
    _tool = null;
    return true;
  }

  void _scroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    // Zoom about the pointer: the pixel under it stays under it.
    final before = (e.localPosition - _origin) / s.zoom.value;
    s.zoomBy(e.scrollDelta.dy < 0 ? 1 : -1);
    final after = _origin + before * s.zoom.value;
    s.pan.value += e.localPosition - after;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        _viewSize = box.biggest;
        if (!_fitted && _viewSize.shortestSide > 0) {
          _fitted = true;
          // After this build: it sets signals this widget listens to.
          scheduleMicrotask(() {
            if (mounted) s.zoomToFit(_viewSize);
          });
        }
        return SignalConsumer(
          signals: [
            s.zoom,
            s.pan,
            s.selection,
            s.symmetry,
            s.showGrid,
            s.tool,
            s.brushSize,
          ],
          builder: (context, _) => MouseRegion(
            cursor: SystemMouseCursors.precise,
            onExit: (_) => setState(() => _hover = null),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerHover: _move,
              onPointerUp: _up,
              onPointerCancel: (e) {
                _panning = false;
                cancelGesture();
              },
              onPointerSignal: _scroll,
              child: ClipRect(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _CanvasPainter(
                    image: _image,
                    onion: Map.of(_onion),
                    origin: _origin,
                    zoom: s.zoom.value,
                    width: s.document.width,
                    height: s.document.height,
                    selection: s.selection.value,
                    symmetry: s.symmetry.value,
                    showGrid: s.showGrid.value,
                    hover: _hover == null || _panning ? null : pixelAt(_hover!),
                    brush: switch (s.tool.value) {
                      StudioTool.pencil ||
                      StudioTool.eraser ||
                      StudioTool.line ||
                      StudioTool.rectangle ||
                      StudioTool.ellipse => s.brushSize.value,
                      _ => 1,
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CanvasPainter extends CustomPainter {
  _CanvasPainter({
    required this.image,
    required this.onion,
    required this.origin,
    required this.zoom,
    required this.width,
    required this.height,
    required this.selection,
    required this.symmetry,
    required this.showGrid,
    required this.hover,
    required this.brush,
  });

  final ui.Image? image;
  final Map<int, ui.Image> onion;
  final Offset origin;
  final double zoom;
  final int width;
  final int height;
  final SelectionMask? selection;
  final Symmetry symmetry;
  final bool showGrid;
  final ({int x, int y})? hover;
  final int brush;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = StudioTheme.workArea);
    final sprite = origin & Size(width * zoom, height * zoom);

    // Transparency: the checkerboard, two sprite pixels to a square at
    // least, so it never competes with the art.
    canvas
      ..save()
      ..clipRect(sprite);
    final cell = zoom * (zoom >= 8 ? 1 : (8 / zoom).ceil());
    final dark = Paint()..color = StudioTheme.checkerDark;
    canvas.drawRect(sprite, Paint()..color = StudioTheme.checkerLight);
    for (var y = 0; y * cell < sprite.height; y++) {
      for (var x = y.isEven ? 1 : 0; x * cell < sprite.width; x += 2) {
        canvas.drawRect(
          Rect.fromLTWH(
            sprite.left + x * cell,
            sprite.top + y * cell,
            cell,
            cell,
          ),
          dark,
        );
      }
    }
    canvas.restore();

    final src = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    for (final entry in onion.entries) {
      // Frames before are warm, frames after are cool, fainter with distance.
      final tint = entry.key < 0
          ? StudioTheme.onionBefore
          : StudioTheme.onionAfter;
      canvas.drawImageRect(
        entry.value,
        src,
        sprite,
        Paint()
          ..filterQuality = FilterQuality.none
          ..colorFilter = ColorFilter.mode(
            tint.withValues(alpha: 0.45 / entry.key.abs()),
            BlendMode.srcIn,
          ),
      );
    }
    final picture = image;
    if (picture != null && picture.width == width && picture.height == height) {
      canvas.drawImageRect(
        picture,
        src,
        sprite,
        Paint()..filterQuality = FilterQuality.none,
      );
    }

    if (showGrid && zoom >= 8) {
      final line = Paint()
        ..color = StudioTheme.pixelGrid
        ..strokeWidth = 1;
      for (var x = 1; x < width; x++) {
        final dx = sprite.left + x * zoom;
        canvas.drawLine(
          Offset(dx, sprite.top),
          Offset(dx, sprite.bottom),
          line,
        );
      }
      for (var y = 1; y < height; y++) {
        final dy = sprite.top + y * zoom;
        canvas.drawLine(
          Offset(sprite.left, dy),
          Offset(sprite.right, dy),
          line,
        );
      }
    }
    canvas.drawRect(
      sprite.inflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = StudioTheme.border,
    );

    final axis = Paint()
      ..color = StudioTheme.accent.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    if (symmetry == Symmetry.horizontal || symmetry == Symmetry.both) {
      final x = sprite.center.dx;
      canvas.drawLine(
        Offset(x, sprite.top - 8),
        Offset(x, sprite.bottom + 8),
        axis,
      );
    }
    if (symmetry == Symmetry.vertical || symmetry == Symmetry.both) {
      final y = sprite.center.dy;
      canvas.drawLine(
        Offset(sprite.left - 8, y),
        Offset(sprite.right + 8, y),
        axis,
      );
    }

    final mask = selection;
    if (mask != null) _paintSelection(canvas, mask);

    final at = hover;
    if (at != null) {
      for (final b in Raster.brush(brush)) {
        canvas.drawRect(
          Rect.fromLTWH(
            origin.dx + (at.x + b.x) * zoom,
            origin.dy + (at.y + b.y) * zoom,
            zoom,
            zoom,
          ),
          Paint()..color = StudioTheme.hover,
        );
      }
    }
  }

  /// The selection's edge: a segment wherever a selected pixel meets one
  /// that is not, light over dark so it shows on any art.
  void _paintSelection(Canvas canvas, SelectionMask mask) {
    final path = Path();
    final b = mask.bounds;
    for (var y = b.top; y < b.bottom; y++) {
      for (var x = b.left; x < b.right; x++) {
        if (!mask.contains(x, y)) continue;
        final l = origin.dx + x * zoom, t = origin.dy + y * zoom;
        if (!mask.contains(x, y - 1)) {
          path
            ..moveTo(l, t)
            ..lineTo(l + zoom, t);
        }
        if (!mask.contains(x, y + 1)) {
          path
            ..moveTo(l, t + zoom)
            ..lineTo(l + zoom, t + zoom);
        }
        if (!mask.contains(x - 1, y)) {
          path
            ..moveTo(l, t)
            ..lineTo(l, t + zoom);
        }
        if (!mask.contains(x + 1, y)) {
          path
            ..moveTo(l + zoom, t)
            ..lineTo(l + zoom, t + zoom);
        }
      }
    }
    canvas
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0xCC000000),
      )
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white,
      );
  }

  @override
  bool shouldRepaint(_CanvasPainter old) => true;
}
