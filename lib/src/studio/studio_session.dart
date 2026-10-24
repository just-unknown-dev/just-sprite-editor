import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:just_editor_core/just_editor_core.dart'
    show PackageAssetPaths;
import 'package:just_signals/just_signals.dart';

import '../document/document_editor.dart';
import '../document/io/aseprite_importer.dart';
import '../document/io/gif_encoder.dart';
import '../document/io/jsprite_codec.dart';
import '../document/io/sheet_export.dart';
import '../document/pixel_buffer.dart';
import '../document/raster.dart';
import '../document/sprite_document.dart';
import 'studio_files.dart';

/// The tools the studio has, in palette order.
enum StudioTool {
  pencil('Pencil', 'B'),
  eraser('Eraser', 'E'),
  fill('Fill', 'G'),
  picker('Pick colour', 'I'),
  line('Line', 'L'),
  rectangle('Rectangle', 'U'),
  ellipse('Ellipse', 'O'),
  select('Select', 'M'),
  move('Move', 'V');

  const StudioTool(this.label, this.key);

  final String label;

  /// The letter that picks it, as in Aseprite.
  final String key;
}

/// Onion skin: neighbouring frames shown faintly under the one being drawn.
class OnionSkin {
  const OnionSkin({this.enabled = false, this.before = 1, this.after = 1});

  final bool enabled;
  final int before;
  final int after;

  OnionSkin copyWith({bool? enabled, int? before, int? after}) => OnionSkin(
    enabled: enabled ?? this.enabled,
    before: before ?? this.before,
    after: after ?? this.after,
  );
}

/// What saving wrote.
class SavedSprite {
  const SavedSprite(
    this.projectPath,
    this.sheetPath,
    this.atlasPath, {
    this.sheetProblem,
  });

  final String projectPath;
  final String sheetPath;
  final String atlasPath;

  /// Why the sheet and atlas were not written, when they could not be — a
  /// sheet too big for a game to load; null when they were. The project
  /// is saved either way.
  final String? sheetProblem;
}

/// What a save writes, made off the UI thread.
class _Encoded {
  const _Encoded(this.project, this.png, this.atlas, this.sheetProblem);

  final String project;
  final Uint8List? png;
  final String? atlas;
  final String? sheetProblem;
}

/// One open sprite: the document, how it is being looked at, and what the
/// tools are set to. Widgets watch its signals; tools and menus call its
/// methods. Everything that changes the document goes through [editor], so
/// everything can be undone.
class SpriteStudioSession {
  SpriteStudioSession(SpriteDocument document, {this.path, String? root})
    : editor = DocumentEditor(document),
      root = (root ?? Directory.current.path).replaceAll(r'\', '/') {
    if (document.palette.isNotEmpty) primary.value = document.palette.first;
  }

  final DocumentEditor editor;

  /// The project root that [path] is relative to.
  final String root;

  /// Project-relative path of the `.jsprite`, or null for a sprite not yet
  /// saved.
  String? path;

  SpriteDocument get document => editor.document;

  /// Bumped whenever the document changes — pixels or structure. Every
  /// move of a stroke bumps it: only the canvas should watch it.
  final Signal<int> revision = Signal(0, debugLabel: 'spriteRevision');

  /// Bumped when the document's shape or its history changes — a step
  /// recorded, undone or redone, a save — but not by the pixels of a
  /// stroke still being drawn. What the panels and the header watch.
  final Signal<int> structureRevision = Signal(
    0,
    debugLabel: 'spriteStructure',
  );
  int _seenVersion = 0;

  final Signal<int> layerIndex = Signal(0, debugLabel: 'spriteLayer');
  final Signal<int> frameIndex = Signal(0, debugLabel: 'spriteFrame');
  final Signal<StudioTool> tool = Signal(
    StudioTool.pencil,
    debugLabel: 'spriteTool',
  );
  final Signal<int> primary = Signal(0xFF000000, debugLabel: 'primaryColor');
  final Signal<int> secondary = Signal(
    0xFFFFFFFF,
    debugLabel: 'secondaryColor',
  );
  final Signal<int> brushSize = Signal(1, debugLabel: 'brushSize');
  final Signal<bool> pixelPerfect = Signal(true, debugLabel: 'pixelPerfect');
  final Signal<Symmetry> symmetry = Signal(
    Symmetry.none,
    debugLabel: 'symmetry',
  );
  final Signal<bool> filledShapes = Signal(false, debugLabel: 'filledShapes');
  final Signal<bool> contiguousFill = Signal(true, debugLabel: 'contiguous');
  final Signal<bool> showGrid = Signal(true, debugLabel: 'pixelGrid');
  final Signal<OnionSkin> onionSkin = Signal(
    const OnionSkin(),
    debugLabel: 'onionSkin',
  );

  /// Screen pixels per sprite pixel.
  final Signal<double> zoom = Signal(8, debugLabel: 'spriteZoom');

  /// Where the sprite's corner sits from the view's centre, in screen pixels
  /// — (0,0) centres it once [centerInView] has run.
  final Signal<ui.Offset> pan = Signal(ui.Offset.zero, debugLabel: 'spritePan');

  final Signal<SelectionMask?> selection = Signal(
    null,
    debugLabel: 'selection',
  );

  final Signal<bool> isPlaying = Signal(false, debugLabel: 'spritePlaying');

  /// The tag playback is limited to; null plays every frame.
  final Signal<String?> playTag = Signal(null, debugLabel: 'playTag');

  /// Something to tell the artist: "Saved", "Layer is locked".
  final Signal<String?> message = Signal(null, debugLabel: 'studioMessage');

  static const List<double> zoomSteps = [
    1,
    2,
    3,
    4,
    6,
    8,
    12,
    16,
    24,
    32,
    48,
    64,
  ];

  // ── Where we are ─────────────────────────────────────────────────────────

  SpriteLayer get layer =>
      document.layers[layerIndex.value.clamp(0, document.layers.length - 1)];

  SpriteFrame get frame =>
      document.frames[frameIndex.value.clamp(0, document.frames.length - 1)];

  bool get isDirty => editor.isDirty;

  /// The file's name, or what a sprite not yet saved is called.
  String get fileName => path?.split('/').last ?? 'Untitled';

  /// [fileName], with a dot while there is work not saved.
  String get title => isDirty ? '$fileName •' : fileName;

  /// Call after anything changed the document. [structure] says the change
  /// is one the panels show although no step was recorded — a slider
  /// being dragged.
  void changed({bool structure = false}) {
    // Frames or layers may have gone from under the cursor.
    final l = layerIndex.value.clamp(0, document.layers.length - 1);
    final f = frameIndex.value.clamp(0, document.frames.length - 1);
    if (l != layerIndex.value) layerIndex.value = l;
    if (f != frameIndex.value) frameIndex.value = f;
    final s = selection.value;
    if (s != null &&
        (s.width != document.width || s.height != document.height)) {
      selection.value = null;
    }
    if (structure || editor.version != _seenVersion) {
      _seenVersion = editor.version;
      structureRevision.value++;
    }
    revision.value = document.revision;
  }

  /// Whether [layerId] has anything drawn in [frameId]: a timeline dot.
  /// Worked out once per [structureRevision], not on every rebuild.
  bool celHasArt(int layerId, int frameId) {
    if (_artAt != structureRevision.value) {
      _art.clear();
      _artAt = structureRevision.value;
    }
    final cel = document.cel(layerId, frameId);
    if (cel == null) return false;
    return _art[cel] ??= !cel.isBlank;
  }

  final Map<PixelBuffer, bool> _art = Map.identity();
  int _artAt = -1;

  void say(String text) => message.forceSet(text);

  // ── Undoable actions ─────────────────────────────────────────────────────

  /// Starts a stroke on the active cel, or says why not.
  CelStroke? beginStroke(String label) {
    if (!layer.visible) {
      say('"${layer.name}" is hidden.');
      return null;
    }
    final stroke = editor.beginStroke(label, layer.id, frame.id);
    if (stroke == null) say('"${layer.name}" is locked.');
    return stroke;
  }

  void structural(String label, void Function(SpriteDocument doc) change) {
    editor.structural(label, change);
    changed();
  }

  void undo() {
    if (editor.undo()) changed();
  }

  void redo() {
    if (editor.redo()) changed();
  }

  void addLayer() {
    structural('New layer', (d) => d.addLayer(above: layerIndex.value));
    layerIndex.value = (layerIndex.value + 1).clamp(
      0,
      document.layers.length - 1,
    );
  }

  void removeLayer() {
    if (document.layers.length <= 1) return say('A sprite needs one layer.');
    structural('Delete layer', (d) => d.removeLayer(layer.id));
  }

  void duplicateLayer() {
    structural('Duplicate layer', (d) => d.duplicateLayer(layer.id));
    layerIndex.value = (layerIndex.value + 1).clamp(
      0,
      document.layers.length - 1,
    );
  }

  void mergeLayerDown() {
    if (layerIndex.value == 0) return say('Nothing below to merge into.');
    structural('Merge down', (d) => d.mergeDown(layer.id));
    layerIndex.value = (layerIndex.value - 1).clamp(
      0,
      document.layers.length - 1,
    );
  }

  void moveLayer(int delta) {
    final from = layerIndex.value;
    final to = (from + delta).clamp(0, document.layers.length - 1);
    if (to == from) return;
    structural('Move layer', (d) => d.moveLayer(from, to));
    layerIndex.value = to;
  }

  void addFrame({bool duplicate = true}) {
    final at = frameIndex.value;
    structural(duplicate ? 'Duplicate frame' : 'New frame', (d) {
      if (duplicate) {
        d.duplicateFrame(at);
      } else {
        d.addFrame(after: at, durationMs: d.frames[at].durationMs);
      }
    });
    frameIndex.value = (at + 1).clamp(0, document.frames.length - 1);
  }

  void removeFrame() {
    if (document.frames.length <= 1) return say('A sprite needs one frame.');
    structural('Delete frame', (d) => d.removeFrame(frameIndex.value));
  }

  void setFrameDuration(int ms) => structural(
    'Frame duration',
    (d) => d.frames[frameIndex.value].durationMs = ms.clamp(1, 65535),
  );

  /// Tags the frames [from]–[to] (inclusive), with a name not yet taken.
  void addTag(int from, int to, {String name = 'tag'}) {
    var unique = name, n = 2;
    while (document.tagNamed(unique) != null) {
      unique = '$name$n';
      n++;
    }
    structural(
      'New tag',
      (d) => d.tags.add(SpriteTag(name: unique, from: from, to: to)),
    );
  }

  /// Cuts the current frame's picture — every visible layer — into frames
  /// of [frameWidth] × [frameHeight], reading the rows left to right and
  /// leaving out empty cells: for a sheet that was opened as one image.
  /// The sprite becomes those frames, on one layer, as one step that undo
  /// takes back. Returns how many frames it made.
  int sliceIntoFrames(int frameWidth, int frameHeight) {
    final sliced = SheetImporter.fromSheet(
      document.flatten(frameIndex.value),
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      durationMs: frame.durationMs,
    )..palette.addAll(document.palette);
    stop();
    structural('Slice into frames', (d) => d.replaceWith(sliced));
    layerIndex.value = 0;
    frameIndex.value = 0;
    return document.frames.length;
  }

  // ── Frames and playback ──────────────────────────────────────────────────

  void goToFrame(int index) =>
      frameIndex.value = index.clamp(0, document.frames.length - 1);

  void stepFrame(int delta) {
    final n = document.frames.length;
    goToFrame(((frameIndex.value + delta) % n + n) % n);
  }

  /// The frames playback visits, in order.
  List<int> get playOrder {
    final tag = playTag.value == null
        ? null
        : document.tagNamed(playTag.value!);
    return tag?.playOrder ??
        [for (var i = 0; i < document.frames.length; i++) i];
  }

  Timer? _playTimer;
  int _playCursor = 0;

  void togglePlay() => isPlaying.value ? stop() : play();

  void play() {
    if (document.frames.length < 2) return;
    final order = playOrder;
    final at = order.indexOf(frameIndex.value);
    _playCursor = at < 0 ? 0 : at;
    isPlaying.value = true;
    _scheduleNext();
  }

  void _scheduleNext() {
    _playTimer?.cancel();
    final order = playOrder;
    if (order.isEmpty || !isPlaying.value) return;
    final current = order[_playCursor % order.length].clamp(
      0,
      document.frames.length - 1,
    );
    _playTimer = Timer(
      Duration(milliseconds: document.frames[current].durationMs),
      () {
        if (!isPlaying.value) return;
        final now = playOrder;
        if (now.isEmpty) return stop();
        _playCursor = (_playCursor + 1) % now.length;
        goToFrame(now[_playCursor]);
        _scheduleNext();
      },
    );
  }

  void stop() {
    _playTimer?.cancel();
    _playTimer = null;
    isPlaying.value = false;
  }

  // ── View ─────────────────────────────────────────────────────────────────

  void zoomBy(int steps) {
    final i = zoomSteps.indexWhere((z) => z >= zoom.value);
    final at = i < 0 ? zoomSteps.length - 1 : i;
    zoom.value = zoomSteps[(at + steps).clamp(0, zoomSteps.length - 1)];
  }

  /// The largest zoom step at which the whole sprite fits [viewSize].
  void zoomToFit(ui.Size viewSize) {
    var best = zoomSteps.first;
    for (final z in zoomSteps) {
      if (document.width * z <= viewSize.width - 48 &&
          document.height * z <= viewSize.height - 48) {
        best = z;
      }
    }
    zoom.value = best;
    pan.value = ui.Offset.zero;
  }

  void swapColors() {
    final p = primary.value;
    primary.value = secondary.value;
    secondary.value = p;
  }

  // ── Files ────────────────────────────────────────────────────────────────

  /// [relative]'s file: a package's own folder for `packages/<name>/…`.
  File _file(String relative) => PackageAssetPaths.of(root).file(relative);

  static String _withoutExtension(String p) {
    final dot = p.lastIndexOf('.');
    return dot <= p.lastIndexOf('/') ? p : p.substring(0, dot);
  }

  /// Saves the project to [to] (or where it already lives) and re-exports
  /// the sheet and atlas JSON beside it, so the game is never a step behind
  /// the drawing.
  ///
  /// The first save keeps what was there before any project was — an
  /// imported image, an atlas some other tool wrote — as
  /// `name.original.png` and `name.original.json`. Each file is written
  /// whole or not at all, the project last. Throws [StateError] for a
  /// sprite too big to save ([SpriteDocument.fitsForSaving]); a sheet too
  /// big for a game to load is left unwritten, and
  /// [SavedSprite.sheetProblem] says why.
  Future<SavedSprite> save({String? to, SheetExportOptions? options}) async {
    final target = to ?? path;
    if (target == null) {
      throw StateError('A new sprite needs a path to save to.');
    }
    if (!document.fitsForSaving) throw StateError(tooBigToSaveMessage);
    final base = _withoutExtension(target);
    final project = '$base.${JspriteCodec.extension}';
    final name = base.split('/').last;
    // What is saved is the document as it is now; anything drawn while the
    // files are written belongs to the next save.
    final version = editor.version;
    final encoded = await _encode(
      document,
      name,
      options ?? document.exportOptions,
    );
    await _file(project).parent.create(recursive: true);
    // What was here before any project was is somebody's original work,
    // imported: keep it, once, rather than write the export over it.
    if (!await _file(project).exists()) {
      for (final ext in const ['png', 'json']) {
        final was = _file('$base.$ext');
        final keep = _file('$base.original.$ext');
        if (await was.exists() && !await keep.exists()) {
          await was.copy(keep.path);
        }
      }
    }
    if (encoded.png != null) {
      await writeAtomically(_file('$base.png'), encoded.png!);
      await writeAtomically(_file('$base.json'), utf8.encode(encoded.atlas!));
    }
    await writeAtomically(_file(project), utf8.encode(encoded.project));
    path = project;
    if (editor.version == version) editor.markSaved();
    changed();
    say(
      encoded.sheetProblem == null
          ? 'Saved $name'
          : 'Saved $name, but not its sheet: ${encoded.sheetProblem}',
    );
    return SavedSprite(
      project,
      '$base.png',
      '$base.json',
      sheetProblem: encoded.sheetProblem,
    );
  }

  /// Why this sprite cannot be saved as it is: bigger than
  /// [SpriteDocument.maxSize].
  String get tooBigToSaveMessage =>
      'This picture is ${document.width} × ${document.height}; a sprite can '
      'be at most ${SpriteDocument.maxSize} × ${SpriteDocument.maxSize}. '
      'Slice it into frames, crop it or make the canvas smaller, then save.';

  // Static, so that the closure sent to the other isolate holds only what
  // it is given — never the session, its signals and its timers.
  static Future<_Encoded> _encode(
    SpriteDocument doc,
    String name,
    SheetExportOptions options,
  ) => Isolate.run(() {
    final project = JspriteCodec.encode(doc);
    try {
      final export = SheetExporter.export(
        doc,
        name: name,
        imageFile: '$name.png',
        options: options,
      );
      return _Encoded(project, export.pngBytes, export.jsonText, null);
    } on ArgumentError catch (e) {
      return _Encoded(project, null, null, '${e.message}');
    }
  });

  /// The project files saving to [target] would write over that this
  /// sprite did not write itself — for a host to ask about first. Empty
  /// when [target] is where this sprite already lives.
  ///
  /// A new sprite (or one saved somewhere new) is in the way of anything
  /// there: another sprite's project, a sheet, an atlas. A sprite opened
  /// from an image, saved beside it for the first time, is only in the way
  /// of an atlas: the image is what it was opened from.
  Future<List<String>> filesInTheWay(String target) async {
    final base = _withoutExtension(target);
    final project = '$base.${JspriteCodec.extension}';
    final own = path != null && _withoutExtension(path!) == base;
    if (own && await _file(project).exists()) return const [];
    return [
      for (final p in [project, '$base.png', '$base.json'])
        if ((!own || p.endsWith('.json')) && await _file(p).exists()) p,
    ];
  }

  /// Writes the animation — the tag being played, or every frame — as a GIF
  /// beside the project, scaled up so it is worth looking at. Returns its
  /// path.
  Future<String> exportGif() async {
    final target = path;
    if (target == null) throw StateError('Save the sprite first.');
    final tag = playTag.value == null
        ? null
        : document.tagNamed(playTag.value!);
    final longest = document.width > document.height
        ? document.width
        : document.height;
    final scale = (192 / longest).floor().clamp(1, 8);
    // A tag's name is the artist's: made safe before it is a file's.
    final suffix = tag == null ? '' : '_${safeFileName(tag.name)}';
    final out = '${_withoutExtension(target)}$suffix.gif';
    final gif = await _encodeGif(document, tag, scale);
    await writeAtomically(_file(out), gif);
    say('Exported ${out.split('/').last} at $scale×');
    return out;
  }

  static Future<Uint8List> _encodeGif(
    SpriteDocument doc,
    SpriteTag? tag,
    int scale,
  ) =>
      Isolate.run(() => GifEncoder.encodeDocument(doc, tag: tag, scale: scale));

  /// Opens [relativePath]: a `.jsprite` project, or an image to start one
  /// from. [decodeImage] turns image bytes into pixels (the UI supplies it;
  /// the core has no image decoder).
  static Future<SpriteStudioSession> open(
    String relativePath, {
    String? root,
    required Future<PixelBuffer> Function(List<int> bytes) decodeImage,
  }) async {
    final base = (root ?? Directory.current.path).replaceAll(r'\', '/');
    final file = File('$base/$relativePath');
    final lower = relativePath.toLowerCase();
    if (lower.endsWith('.${JspriteCodec.extension}')) {
      return SpriteStudioSession(
        JspriteCodec.decode(await file.readAsString()),
        path: relativePath,
        root: base,
      );
    }
    // An image: if a project already sits beside it, that is the editable
    // original — the image is only its export.
    final sibling =
        '${_withoutExtension(relativePath)}.${JspriteCodec.extension}';
    if (await File('$base/$sibling').exists()) {
      return SpriteStudioSession(
        JspriteCodec.decode(await File('$base/$sibling').readAsString()),
        path: sibling,
        root: base,
      );
    }
    if (lower.endsWith('.aseprite') || lower.endsWith('.ase')) {
      final (doc, warnings) = AsepriteImporter.import(await file.readAsBytes());
      return SpriteStudioSession(doc, path: sibling, root: base)..say(
        warnings.isEmpty
            ? 'Imported from Aseprite — saving makes a project.'
            : 'Imported. ${warnings.join(' ')}',
      );
    }
    final image = await decodeImage(await file.readAsBytes());
    final session = SpriteStudioSession(
      SheetImporter.fromImage(image),
      path: sibling,
      root: base,
    );
    return session..say(
      session.document.fitsForSaving
          ? 'Imported ${relativePath.split('/').last} — saving makes a '
                'project.'
          : session.tooBigToSaveMessage,
    );
  }

  void dispose() {
    stop();
    for (final s in <Signal<Object?>>[
      revision,
      structureRevision,
      layerIndex,
      frameIndex,
      tool,
      primary,
      secondary,
      brushSize,
      pixelPerfect,
      symmetry,
      filledShapes,
      contiguousFill,
      showGrid,
      onionSkin,
      zoom,
      pan,
      selection,
      isPlaying,
      playTag,
      message,
    ]) {
      s.dispose();
    }
  }
}
