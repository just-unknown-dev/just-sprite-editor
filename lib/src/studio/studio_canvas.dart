import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:just_signals/just_signals.dart';

import '../document/io/sheet_export.dart';
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
///
/// Throws [FormatException] for an image too big to open
/// ([SheetImporter.checkImportSize]) — found from its header, before any
/// of it is decoded.
Future<PixelBuffer> pixelsFromImageBytes(List<int> bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(
    Uint8List.fromList(bytes),
  );
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    SheetImporter.checkImportSize(descriptor.width, descriptor.height);
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (data == null) {
      throw const FormatException('The image could not be read.');
    }
    return PixelBuffer.fromRgbaBytes(
      image.width,
      image.height,
      data.buffer.asUint8List(),
    );
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
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

  /// The frame being drawn, on the GPU.
  ui.Image? _image;

  /// Onion-skin frames on the GPU, by frame id: kept while the document's
  /// structure stays as it was ([SpriteStudioSession.structureRevision]),
  /// since a stroke only ever changes the frame being drawn.
  final Map<int, ui.Image> _onionCache = {};
  int _onionStamp = -1;

  /// What the painter shows of [_onionCache]: by distance from the frame
  /// being drawn, negative before it.
  Map<int, ui.Image> _onion = const {};

  List<VoidCallback> _stop = const [];

  // One refresh at a time, at most one a frame.
  bool _scheduled = false;
  bool _busy = false;
  bool _again = false;

  PixelTool? _tool;
  bool _panning = false;
  final ValueNotifier<({int x, int y})?> _hover = ValueNotifier(null);
  Size _viewSize = Size.zero;
  bool _fitted = false;

  // A trackpad pinch: the scale at which the zoom last stepped.
  double _pinchAt = 1;

  /// The GPU images this canvas holds now: the frame and its onion skins.
  @visibleForTesting
  int get liveImageCount => (_image == null ? 0 : 1) + _onionCache.length;

  /// How many onion-skin frames are on screen.
  @visibleForTesting
  int get onionFrameCount => _onion.length;

  /// Whether new GPU images are wanted or being made.
  @visibleForTesting
  bool get isRefreshing => _busy || _scheduled || _again;

  @override
  void initState() {
    super.initState();
    _watch();
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(StudioCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      for (final stop in _stop) {
        stop();
      }
      _fitted = false;
      _dropImages();
      _watch();
      _scheduleRefresh();
    }
  }

  void _watch() {
    _stop = [
      s.revision.watch(_scheduleRefresh),
      s.frameIndex.watch(_scheduleRefresh),
      s.onionSkin.watch(_scheduleRefresh),
      // Onion skins are left out while playing: back when it stops.
      s.isPlaying.watch(_scheduleRefresh),
    ];
  }

  @override
  void dispose() {
    for (final stop in _stop) {
      stop();
    }
    _dropImages();
    _hover.dispose();
    super.dispose();
  }

  void _dropImages() {
    _image?.dispose();
    _image = null;
    for (final image in _onionCache.values) {
      image.dispose();
    }
    _onionCache.clear();
    _onion = const {};
    _onionStamp = -1;
  }

  /// Asks for the GPU images to be made again — once, before the next
  /// frame, however many changes arrive meanwhile.
  void _scheduleRefresh() {
    if (_busy) {
      _again = true;
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance
      ..scheduleFrameCallback((_) {
        _scheduled = false;
        if (mounted) _refresh();
      })
      ..scheduleFrame();
  }

  /// Makes the GPU images of the frame (and its onion neighbours). The old
  /// image keeps showing until the new one is ready, so nothing flashes.
  Future<void> _refresh() async {
    _busy = true;
    _again = false;
    final session = s;
    final made = <ui.Image>[];
    try {
      final doc = session.document;
      final at = session.frameIndex.value.clamp(0, doc.frames.length - 1);
      final onion = session.onionSkin.value;
      final stamp = session.structureRevision.value;
      final offsets = <int>[
        if (onion.enabled && !session.isPlaying.value) ...[
          for (var i = 1; i <= onion.before; i++)
            if (at - i >= 0) -i,
          for (var i = 1; i <= onion.after; i++)
            if (at + i < doc.frames.length) i,
        ],
      ];
      final reusable = stamp == _onionStamp
          ? _onionCache
          : const <int, ui.Image>{};
      final image = await imageFromPixels(doc.flatten(at));
      made.add(image);
      final skins = <int, ui.Image>{};
      for (final offset in offsets) {
        final id = doc.frames[at + offset].id;
        final cached = reusable[id];
        if (cached != null) {
          skins[id] = cached;
        } else {
          final fresh = await imageFromPixels(doc.flatten(at + offset));
          made.add(fresh);
          skins[id] = fresh;
        }
      }
      if (!mounted || session != s) {
        for (final i in made) {
          i.dispose();
        }
        if (mounted) _again = true;
        return;
      }
      final oldImage = _image;
      final evicted = [
        for (final e in _onionCache.entries)
          if (!identical(skins[e.key], e.value)) e.value,
      ];
      setState(() {
        _image = image;
        _onionCache
          ..clear()
          ..addAll(skins);
        _onionStamp = stamp;
        _onion = {
          for (final offset in offsets)
            offset: skins[doc.frames[at + offset].id]!,
        };
      });
      // A picture already painted keeps what it drew; these handles are
      // all that is let go.
      oldImage?.dispose();
      for (final i in evicted) {
        i.dispose();
      }
    } finally {
      _busy = false;
      if (_again && mounted) _scheduleRefresh();
    }
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
      _hover.value = null;
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
    // Only the brush outline follows the pointer: the sprite is not
    // painted again for it.
    _hover.value = p;
  }

  void _up(PointerEvent e) {
    _panning = false;
    _tool?.up(s);
    _tool = null;
  }

  /// Whether a gesture is in progress on the canvas.
  bool get isDrawing => _tool != null;

  /// Abandons the gesture in progress. True if there was one.
  bool cancelGesture() {
    final tool = _tool;
    if (tool == null) return false;
    tool.cancel(s);
    _tool = null;
    return true;
  }

  /// Finishes the gesture in progress as if the pointer had come up — what
  /// drawn so far is one step — and draws no more until the next one. For
  /// a key that edits the sprite mid-stroke: undo then takes back the
  /// stroke, and nothing drawn after lands outside the history. True if
  /// there was one.
  bool endGesture() {
    final tool = _tool;
    if (tool == null) return false;
    tool.up(s);
    _tool = null;
    return true;
  }

  /// Zooms by [steps] about [local]: the pixel under it stays under it.
  void _zoomAbout(Offset local, int steps) {
    final before = (local - _origin) / s.zoom.value;
    s.zoomBy(steps);
    final after = _origin + before * s.zoom.value;
    s.pan.value += local - after;
  }

  void _scroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    _zoomAbout(e.localPosition, e.scrollDelta.dy < 0 ? 1 : -1);
  }

  // A trackpad (a Mac's above all): two fingers pan, a pinch zooms.
  void _panZoomStart(PointerPanZoomStartEvent e) => _pinchAt = 1;

  void _panZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (e.localPanDelta != Offset.zero) s.pan.value += e.localPanDelta;
    if (e.scale >= _pinchAt * 1.25) {
      _pinchAt = e.scale;
      _zoomAbout(e.localPosition, 1);
    } else if (e.scale <= _pinchAt * 0.8) {
      _pinchAt = e.scale;
      _zoomAbout(e.localPosition, -1);
    }
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
          builder: (context, _) {
            final origin = _origin;
            final zoom = s.zoom.value;
            final w = s.document.width, h = s.document.height;
            return MouseRegion(
              cursor: SystemMouseCursors.precise,
              onExit: (_) => _hover.value = null,
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
                onPointerPanZoomStart: _panZoomStart,
                onPointerPanZoomUpdate: _panZoomUpdate,
                child: ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Each layer repaints for its own reasons only: the
                      // checkerboard when the view moves, the sprite when
                      // its picture is new, the brush outline as the
                      // pointer moves.
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: BackdropPainter(
                            origin: origin,
                            zoom: zoom,
                            width: w,
                            height: h,
                          ),
                        ),
                      ),
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: _SpritePainter(
                            image: _image,
                            onion: _onion,
                            origin: origin,
                            zoom: zoom,
                            width: w,
                            height: h,
                          ),
                        ),
                      ),
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: _OverlayPainter(
                            origin: origin,
                            zoom: zoom,
                            width: w,
                            height: h,
                            selection: s.selection.value,
                            symmetry: s.symmetry.value,
                            showGrid: s.showGrid.value,
                          ),
                        ),
                      ),
                      CustomPaint(
                        painter: _HoverPainter(
                          hover: _hover,
                          origin: origin,
                          zoom: zoom,
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
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// The part of [sprite] that shows in a view of [size].
Rect _visible(Rect sprite, Size size) => sprite.intersect(Offset.zero & size);

/// The work area, and the checkerboard under the sprite — only the squares
/// in view, however large the sprite and however far it is zoomed.
@visibleForTesting
class BackdropPainter extends CustomPainter {
  BackdropPainter({
    required this.origin,
    required this.zoom,
    required this.width,
    required this.height,
  });

  final Offset origin;
  final double zoom;
  final int width;
  final int height;

  /// How many dark squares the last paint drew.
  @visibleForTesting
  int squaresPainted = 0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = StudioTheme.workArea);
    final sprite = origin & Size(width * zoom, height * zoom);
    final shown = _visible(sprite, size);
    if (shown.isEmpty) return;

    // Two sprite pixels to a square at least when zoomed out, so it never
    // competes with the art.
    final cell = zoom * (zoom >= 8 ? 1 : (8 / zoom).ceil());
    final dark = Paint()..color = StudioTheme.checkerDark;
    canvas.drawRect(shown, Paint()..color = StudioTheme.checkerLight);
    final x0 = ((shown.left - sprite.left) / cell).floor();
    final x1 = ((shown.right - sprite.left) / cell).ceil();
    final y0 = ((shown.top - sprite.top) / cell).floor();
    final y1 = ((shown.bottom - sprite.top) / cell).ceil();
    canvas
      ..save()
      ..clipRect(shown);
    var squares = 0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0 + ((x0 + y).isEven ? 1 : 0); x < x1; x += 2) {
        canvas.drawRect(
          Rect.fromLTWH(
            sprite.left + x * cell,
            sprite.top + y * cell,
            cell,
            cell,
          ),
          dark,
        );
        squares++;
      }
    }
    canvas.restore();
    squaresPainted = squares;
  }

  @override
  bool shouldRepaint(BackdropPainter old) =>
      old.origin != origin ||
      old.zoom != zoom ||
      old.width != width ||
      old.height != height;
}

/// The sprite and its onion skins.
class _SpritePainter extends CustomPainter {
  _SpritePainter({
    required this.image,
    required this.onion,
    required this.origin,
    required this.zoom,
    required this.width,
    required this.height,
  });

  final ui.Image? image;
  final Map<int, ui.Image> onion;
  final Offset origin;
  final double zoom;
  final int width;
  final int height;

  @override
  void paint(Canvas canvas, Size size) {
    final sprite = origin & Size(width * zoom, height * zoom);
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
  }

  @override
  bool shouldRepaint(_SpritePainter old) =>
      !identical(old.image, image) ||
      !identical(old.onion, onion) ||
      old.origin != origin ||
      old.zoom != zoom ||
      old.width != width ||
      old.height != height;
}

/// The pixel grid, the border, the symmetry axes and the selection's edge.
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.origin,
    required this.zoom,
    required this.width,
    required this.height,
    required this.selection,
    required this.symmetry,
    required this.showGrid,
  });

  final Offset origin;
  final double zoom;
  final int width;
  final int height;
  final SelectionMask? selection;
  final Symmetry symmetry;
  final bool showGrid;

  @override
  void paint(Canvas canvas, Size size) {
    final sprite = origin & Size(width * zoom, height * zoom);
    final shown = _visible(sprite, size);

    if (showGrid && zoom >= 8 && !shown.isEmpty) {
      final line = Paint()
        ..color = StudioTheme.pixelGrid
        ..strokeWidth = 1;
      // Only the lines in view.
      final x0 = math.max(1, ((shown.left - sprite.left) / zoom).floor());
      final x1 = math.min(
        width - 1,
        ((shown.right - sprite.left) / zoom).ceil(),
      );
      for (var x = x0; x <= x1; x++) {
        final dx = sprite.left + x * zoom;
        canvas.drawLine(Offset(dx, shown.top), Offset(dx, shown.bottom), line);
      }
      final y0 = math.max(1, ((shown.top - sprite.top) / zoom).floor());
      final y1 = math.min(
        height - 1,
        ((shown.bottom - sprite.top) / zoom).ceil(),
      );
      for (var y = y0; y <= y1; y++) {
        final dy = sprite.top + y * zoom;
        canvas.drawLine(Offset(shown.left, dy), Offset(shown.right, dy), line);
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
  }

  /// The selection's edge — the mask's own outline, worked out once per
  /// mask — light over dark so it shows on any art.
  void _paintSelection(Canvas canvas, SelectionMask mask) {
    final path = Path();
    for (final (x0, y0, x1, y1) in mask.outline) {
      path
        ..moveTo(origin.dx + x0 * zoom, origin.dy + y0 * zoom)
        ..lineTo(origin.dx + x1 * zoom, origin.dy + y1 * zoom);
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
  bool shouldRepaint(_OverlayPainter old) =>
      old.origin != origin ||
      old.zoom != zoom ||
      old.width != width ||
      old.height != height ||
      !identical(old.selection, selection) ||
      old.symmetry != symmetry ||
      old.showGrid != showGrid;
}

/// The brush's outline under the pointer: repainted as [hover] changes,
/// alone.
class _HoverPainter extends CustomPainter {
  _HoverPainter({
    required this.hover,
    required this.origin,
    required this.zoom,
    required this.brush,
  }) : super(repaint: hover);

  final ValueListenable<({int x, int y})?> hover;
  final Offset origin;
  final double zoom;
  final int brush;

  @override
  void paint(Canvas canvas, Size size) {
    final at = hover.value;
    if (at == null) return;
    final paint = Paint()..color = StudioTheme.hover;
    for (final b in Raster.brush(brush)) {
      canvas.drawRect(
        Rect.fromLTWH(
          origin.dx + (at.x + b.x) * zoom,
          origin.dy + (at.y + b.y) * zoom,
          zoom,
          zoom,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HoverPainter old) =>
      old.hover != hover ||
      old.origin != origin ||
      old.zoom != zoom ||
      old.brush != brush;
}
