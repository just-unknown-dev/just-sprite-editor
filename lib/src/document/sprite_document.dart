import 'io/sheet_options.dart';
import 'pixel_buffer.dart';

/// One layer of a sprite: a row of the timeline.
class SpriteLayer {
  SpriteLayer({
    required this.id,
    required this.name,
    this.visible = true,
    this.locked = false,
    this.opacity = 255,
  });

  final int id;
  String name;
  bool visible;
  bool locked;

  /// 0–255.
  int opacity;

  SpriteLayer clone() => SpriteLayer(
    id: id,
    name: name,
    visible: visible,
    locked: locked,
    opacity: opacity,
  );
}

/// One frame of a sprite: a column of the timeline.
class SpriteFrame {
  SpriteFrame({required this.id, this.durationMs = 100});

  final int id;
  int durationMs;

  SpriteFrame clone() => SpriteFrame(id: id, durationMs: durationMs);
}

/// How a tag's frames play.
enum TagDirection { forward, reverse, pingpong }

/// Something the artist wants the game to hear at a moment in a clip.
class SpriteEvent {
  const SpriteEvent({required this.timeMs, required this.name});

  /// Milliseconds from the start of the tag's playback.
  final int timeMs;
  final String name;
}

/// A named run of frames: a clip. Frames are by index, as in Aseprite, so a
/// tag follows its place in the timeline.
class SpriteTag {
  SpriteTag({
    required this.name,
    required this.from,
    required this.to,
    this.direction = TagDirection.forward,
    this.loop = true,
    this.color = 0xFF7DE6B1,
    List<SpriteEvent>? events,
  }) : events = events ?? [];

  String name;
  int from;
  int to;
  TagDirection direction;
  bool loop;
  int color;
  List<SpriteEvent> events;

  SpriteTag clone() => SpriteTag(
    name: name,
    from: from,
    to: to,
    direction: direction,
    loop: loop,
    color: color,
    events: List.of(events),
  );

  /// The frame indices in playing order, as the engine's atlas loader plays
  /// an Aseprite tag: a ping-pong comes back without repeating either end.
  List<int> get playOrder {
    final forward = [for (var i = from; i <= to; i++) i];
    return switch (direction) {
      TagDirection.forward => forward,
      TagDirection.reverse => forward.reversed.toList(),
      TagDirection.pingpong => [
        ...forward,
        if (forward.length > 2)
          ...forward.reversed.skip(1).take(forward.length - 2),
      ],
    };
  }
}

/// Everything about a document except the pixels inside its cels: what an
/// undo step for a structural change keeps. Cel buffers are shared, not
/// copied — pixel edits are undone by their own patches before a snapshot
/// that refers to the same buffer is ever restored.
class DocumentStructure {
  DocumentStructure._(
    this.width,
    this.height,
    this.layers,
    this.frames,
    this.tags,
    this.palette,
    this.cels,
    this.exportOptions,
  );

  final int width;
  final int height;
  final List<SpriteLayer> layers;
  final List<SpriteFrame> frames;
  final List<SpriteTag> tags;
  final List<int> palette;
  final Map<int, PixelBuffer> cels;
  final SheetExportOptions exportOptions;
}

/// A sprite: a canvas size, layers bottom to top, frames in order, and a
/// cel — a canvas-sized buffer — wherever a layer has something in a frame.
class SpriteDocument {
  SpriteDocument({required this.width, required this.height})
    : assert(width > 0 && height > 0);

  /// A blank sprite with one layer and one frame.
  factory SpriteDocument.blank(int width, int height, {List<int>? palette}) {
    final doc = SpriteDocument(width: width, height: height);
    doc
      ..addLayer(name: 'Layer 1')
      ..addFrame();
    if (palette != null) doc.palette.addAll(palette);
    return doc;
  }

  static const int maxSize = 2048;

  int width;
  int height;

  /// Bottom first.
  final List<SpriteLayer> layers = [];
  final List<SpriteFrame> frames = [];
  final List<SpriteTag> tags = [];
  final List<int> palette = [];

  /// How this sprite's sheet is laid out when it is exported.
  SheetExportOptions exportOptions = const SheetExportOptions(padding: 1);

  final Map<int, PixelBuffer> _cels = {};
  int _nextId = 1;

  /// Bumped by every change, pixel or structural: what a view watches.
  int revision = 0;

  void touch() => revision++;

  IntRect get bounds => IntRect(0, 0, width, height);

  // Ids are small positive ints, so a pair packs into one key.
  static int _key(int layerId, int frameId) => layerId * 0x100000 + frameId;

  // ── Cels ─────────────────────────────────────────────────────────────────

  /// The cel of [layerId] in [frameId], or null where it is empty.
  PixelBuffer? cel(int layerId, int frameId) => _cels[_key(layerId, frameId)];

  /// The cel, made blank if there was none.
  PixelBuffer ensureCel(int layerId, int frameId) =>
      _cels[_key(layerId, frameId)] ??= PixelBuffer(width, height);

  void setCel(int layerId, int frameId, PixelBuffer? buffer) {
    assert(
      buffer == null || (buffer.width == width && buffer.height == height),
    );
    if (buffer == null) {
      _cels.remove(_key(layerId, frameId));
    } else {
      _cels[_key(layerId, frameId)] = buffer;
    }
    touch();
  }

  int get celCount => _cels.length;

  // ── Layers ───────────────────────────────────────────────────────────────

  SpriteLayer? layerById(int id) {
    for (final l in layers) {
      if (l.id == id) return l;
    }
    return null;
  }

  int layerIndex(int id) => layers.indexWhere((l) => l.id == id);

  /// Adds a layer above [above] (an index), or on top.
  SpriteLayer addLayer({String? name, int? above}) {
    final layer = SpriteLayer(
      id: _nextId++,
      name: name ?? 'Layer ${layers.length + 1}',
    );
    final at = above == null
        ? layers.length
        : (above + 1).clamp(0, layers.length);
    layers.insert(at, layer);
    touch();
    return layer;
  }

  /// Removes a layer and its cels. The last layer stays.
  bool removeLayer(int id) {
    if (layers.length <= 1) return false;
    final i = layerIndex(id);
    if (i < 0) return false;
    layers.removeAt(i);
    for (final f in frames) {
      _cels.remove(_key(id, f.id));
    }
    touch();
    return true;
  }

  void moveLayer(int from, int to) {
    if (from < 0 || from >= layers.length) return;
    final layer = layers.removeAt(from);
    layers.insert(to.clamp(0, layers.length), layer);
    touch();
  }

  /// A copy of the layer, with copies of its cels, right above it.
  SpriteLayer? duplicateLayer(int id) {
    final i = layerIndex(id);
    if (i < 0) return null;
    final source = layers[i];
    final copy = SpriteLayer(
      id: _nextId++,
      name: '${source.name} copy',
      visible: source.visible,
      opacity: source.opacity,
    );
    layers.insert(i + 1, copy);
    for (final f in frames) {
      final c = cel(id, f.id);
      if (c != null) _cels[_key(copy.id, f.id)] = c.copy();
    }
    touch();
    return copy;
  }

  /// Draws [upperId] onto the layer below it and removes it.
  bool mergeDown(int upperId) {
    final i = layerIndex(upperId);
    if (i <= 0) return false;
    final upper = layers[i];
    final lower = layers[i - 1];
    for (final f in frames) {
      final top = cel(upper.id, f.id);
      if (top == null) continue;
      // A fresh buffer, so an undo snapshot's buffer is left as it was.
      final merged = (cel(lower.id, f.id) ?? PixelBuffer(width, height)).copy()
        ..composite(top, 0, 0, opacity: upper.opacity);
      _cels[_key(lower.id, f.id)] = merged;
    }
    return removeLayer(upperId);
  }

  // ── Frames ───────────────────────────────────────────────────────────────

  int frameIndex(int id) => frames.indexWhere((f) => f.id == id);

  /// Adds an empty frame after [after] (an index), or at the end. Tags that
  /// start later shift; a tag the frame lands inside grows.
  SpriteFrame addFrame({int? after, int durationMs = 100}) {
    final frame = SpriteFrame(id: _nextId++, durationMs: durationMs);
    final at = after == null
        ? frames.length
        : (after + 1).clamp(0, frames.length);
    frames.insert(at, frame);
    for (final t in tags) {
      if (t.from >= at) t.from++;
      if (t.to >= at) t.to++;
    }
    touch();
    return frame;
  }

  /// A copy of the frame — every layer's cel — right after it.
  SpriteFrame? duplicateFrame(int index) {
    if (index < 0 || index >= frames.length) return null;
    final source = frames[index];
    final copy = addFrame(after: index, durationMs: source.durationMs);
    for (final l in layers) {
      final c = cel(l.id, source.id);
      if (c != null) _cels[_key(l.id, copy.id)] = c.copy();
    }
    touch();
    return copy;
  }

  /// Removes a frame and its cels. The last frame stays. Tags shrink; one
  /// left with no frames goes.
  bool removeFrame(int index) {
    if (frames.length <= 1 || index < 0 || index >= frames.length) return false;
    final frame = frames.removeAt(index);
    for (final l in layers) {
      _cels.remove(_key(l.id, frame.id));
    }
    tags.removeWhere((t) => t.from == index && t.to == index);
    for (final t in tags) {
      if (t.from > index) t.from--;
      if (t.to >= index) t.to--;
    }
    touch();
    return true;
  }

  void moveFrame(int from, int to) {
    if (from < 0 || from >= frames.length) return;
    final frame = frames.removeAt(from);
    frames.insert(to.clamp(0, frames.length), frame);
    touch();
  }

  /// Total length of [tag]'s playback, or of every frame when null, in ms.
  int durationMs([SpriteTag? tag]) {
    final order = tag?.playOrder ?? [for (var i = 0; i < frames.length; i++) i];
    var total = 0;
    for (final i in order) {
      if (i >= 0 && i < frames.length) total += frames[i].durationMs;
    }
    return total;
  }

  SpriteTag? tagNamed(String name) {
    for (final t in tags) {
      if (t.name == name) return t;
    }
    return null;
  }

  // ── The picture ──────────────────────────────────────────────────────────

  /// Frame [frameIndex] with every visible layer drawn, bottom to top.
  PixelBuffer flatten(int frameIndex, {bool onlyVisible = true}) {
    final out = PixelBuffer(width, height);
    if (frameIndex < 0 || frameIndex >= frames.length) return out;
    final frameId = frames[frameIndex].id;
    for (final l in layers) {
      if (onlyVisible && !l.visible) continue;
      final c = cel(l.id, frameId);
      if (c != null) out.composite(c, 0, 0, opacity: l.opacity);
    }
    return out;
  }

  // ── Whole-canvas changes ─────────────────────────────────────────────────

  /// Replaces every cel with [change] of it and adopts the new size. Used
  /// for canvas resize, crop, flip and rotate.
  void transformCanvas(
    int newWidth,
    int newHeight,
    PixelBuffer Function(PixelBuffer cel) change,
  ) {
    assert(newWidth > 0 && newHeight > 0);
    for (final key in _cels.keys.toList()) {
      final next = change(_cels[key]!);
      assert(next.width == newWidth && next.height == newHeight);
      _cels[key] = next;
    }
    width = newWidth;
    height = newHeight;
    touch();
  }

  void resizeCanvas(int newWidth, int newHeight, {int dx = 0, int dy = 0}) =>
      transformCanvas(
        newWidth,
        newHeight,
        (c) => c.resizedCanvas(newWidth, newHeight, dx: dx, dy: dy),
      );

  void cropTo(IntRect rect) {
    final r = rect.intersect(bounds);
    if (r.isEmpty) return;
    transformCanvas(r.width, r.height, (c) => c.copyRect(r));
  }

  void flipCanvas({required bool horizontal}) => transformCanvas(
    width,
    height,
    (c) => horizontal ? c.flippedHorizontally() : c.flippedVertically(),
  );

  void rotateCanvas({bool clockwise = true}) =>
      transformCanvas(height, width, (c) => c.rotated90(clockwise: clockwise));

  /// Drops cels with nothing in them.
  void pruneBlankCels() {
    _cels.removeWhere((_, c) => c.isBlank);
  }

  // ── Undo support ─────────────────────────────────────────────────────────

  DocumentStructure snapshot() => DocumentStructure._(
    width,
    height,
    [for (final l in layers) l.clone()],
    [for (final f in frames) f.clone()],
    [for (final t in tags) t.clone()],
    List.of(palette),
    Map.of(_cels),
    exportOptions,
  );

  void restore(DocumentStructure s) {
    width = s.width;
    height = s.height;
    layers
      ..clear()
      ..addAll([for (final l in s.layers) l.clone()]);
    frames
      ..clear()
      ..addAll([for (final f in s.frames) f.clone()]);
    tags
      ..clear()
      ..addAll([for (final t in s.tags) t.clone()]);
    palette
      ..clear()
      ..addAll(s.palette);
    _cels
      ..clear()
      ..addAll(s.cels);
    exportOptions = s.exportOptions;
    touch();
  }

  /// For a codec rebuilding a saved document: the id the next layer or
  /// frame gets must be past every one in use.
  void reserveIds(int highestUsed) {
    if (highestUsed >= _nextId) _nextId = highestUsed + 1;
  }
}
