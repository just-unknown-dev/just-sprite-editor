import 'pixel_buffer.dart';
import 'sprite_document.dart';

/// One undoable step.
abstract class DocumentCommand {
  String get label;
  void redo(SpriteDocument doc);
  void undo(SpriteDocument doc);

  /// Rough bytes held, so the stack can stay within a budget.
  int get weight;
}

/// A change to the pixels of one cel: the touched rectangle, before and
/// after. A stroke across a 256² canvas that touched a 9×9 corner keeps 162
/// pixels, not two canvases.
class CelPatchCommand extends DocumentCommand {
  CelPatchCommand({
    required this.label,
    required this.layerId,
    required this.frameId,
    required this.rect,
    required this.before,
    required this.after,
    required this.createdCel,
  });

  @override
  final String label;
  final int layerId;
  final int frameId;
  final IntRect rect;
  final PixelBuffer before;
  final PixelBuffer after;

  /// The cel did not exist before this; undoing removes it again.
  final bool createdCel;

  @override
  int get weight => (before.pixels.length + after.pixels.length) * 4;

  @override
  void redo(SpriteDocument doc) {
    doc.ensureCel(layerId, frameId).paste(after, rect.left, rect.top);
    doc.touch();
  }

  @override
  void undo(SpriteDocument doc) {
    if (createdCel) {
      doc.setCel(layerId, frameId, null);
      return;
    }
    doc.ensureCel(layerId, frameId).paste(before, rect.left, rect.top);
    doc.touch();
  }
}

/// A change to the document's shape — layers, frames, tags, palette, canvas
/// size — kept as the structure before and after.
class StructureCommand extends DocumentCommand {
  StructureCommand(this.label, this.before, this.after);

  @override
  final String label;
  final DocumentStructure before;
  final DocumentStructure after;

  // Structures share cel buffers; what they hold of their own is small.
  @override
  int get weight => 1024;

  @override
  void redo(SpriteDocument doc) => doc.restore(after);

  @override
  void undo(SpriteDocument doc) => doc.restore(before);
}

/// Pixels being drawn into one cel. Tools draw through [buffer]; [commit]
/// turns whatever changed into one undo step.
class CelStroke {
  CelStroke._(this._editor, this.label, this.layerId, this.frameId)
    : _existed = _editor.document.cel(layerId, frameId) != null,
      buffer = _editor.document.ensureCel(layerId, frameId) {
    _before = buffer.copy();
  }

  final DocumentEditor _editor;
  final String label;
  final int layerId;
  final int frameId;
  final bool _existed;

  /// The live cel: what is drawn here shows at once.
  final PixelBuffer buffer;
  late final PixelBuffer _before;
  bool _done = false;

  /// The cel as it was when the stroke began — for a tool that redraws its
  /// shape from scratch as the pointer moves.
  PixelBuffer get original => _before;

  /// Puts the cel back as it was when the stroke began, to draw again.
  void reset() => buffer.pixels.setAll(0, _before.pixels);

  /// Ends the stroke as one undo step. False when nothing changed.
  bool commit() {
    if (_done) return false;
    _done = true;
    _editor._stroke = null;
    final rect = _changedRect();
    if (rect.isEmpty) {
      if (!_existed) _editor.document.setCel(layerId, frameId, null);
      return false;
    }
    _editor._record(
      CelPatchCommand(
        label: label,
        layerId: layerId,
        frameId: frameId,
        rect: rect,
        before: _before.copyRect(rect),
        after: buffer.copyRect(rect),
        createdCel: !_existed,
      ),
    );
    _editor.document.touch();
    return true;
  }

  /// Ends the stroke and puts the cel back.
  void cancel() {
    if (_done) return;
    _done = true;
    _editor._stroke = null;
    if (_existed) {
      reset();
      _editor.document.touch();
    } else {
      _editor.document.setCel(layerId, frameId, null);
    }
  }

  IntRect _changedRect() {
    final w = buffer.width, h = buffer.height;
    var minX = w, minY = h, maxX = -1, maxY = -1;
    final a = _before.pixels, b = buffer.pixels;
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        if (a[row + x] == b[row + x]) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    return maxX < 0 ? IntRect.empty : IntRect(minX, minY, maxX + 1, maxY + 1);
  }
}

/// Every change to a [SpriteDocument] goes through here, so every change
/// can be undone.
class DocumentEditor {
  DocumentEditor(
    this.document, {
    this.maxSteps = 200,
    this.maxBytes = 96 << 20,
  });

  final SpriteDocument document;
  final int maxSteps;
  final int maxBytes;

  final List<DocumentCommand> _undo = [];
  final List<DocumentCommand> _redo = [];
  CelStroke? _stroke;
  int _bytes = 0;

  /// The undo-stack depth at the last [markSaved]; null when that point has
  /// been dropped off the stack or overwritten.
  int? _savedAt = 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  /// Whether there is anything since the last [markSaved].
  bool get isDirty => _savedAt != _undo.length;

  void markSaved() => _savedAt = _undo.length;

  /// Starts drawing into a cel. A stroke still open is committed first.
  /// Null for a locked or missing layer.
  CelStroke? beginStroke(String label, int layerId, int frameId) {
    _stroke?.commit();
    final layer = document.layerById(layerId);
    if (layer == null || layer.locked) return null;
    if (document.frameIndex(frameId) < 0) return null;
    return _stroke = CelStroke._(this, label, layerId, frameId);
  }

  /// A change to the document's shape, as one undo step. [change] does it
  /// through the document's own methods.
  void structural(String label, void Function(SpriteDocument doc) change) {
    _stroke?.commit();
    final before = document.snapshot();
    change(document);
    // Whatever it changed — a list the document exposes, a field of a layer
    // — views hear about it.
    document.touch();
    _record(StructureCommand(label, before, document.snapshot()));
  }

  void _record(DocumentCommand command) {
    _undo.add(command);
    _bytes += command.weight;
    if (_redo.isNotEmpty) {
      _redo.clear();
      // The saved point was on the branch just discarded.
      if (_savedAt != null && _savedAt! > _undo.length - 1) _savedAt = null;
    }
    while (_undo.length > maxSteps || (_bytes > maxBytes && _undo.length > 1)) {
      _bytes -= _undo.removeAt(0).weight;
      if (_savedAt != null) _savedAt = _savedAt! > 0 ? _savedAt! - 1 : null;
    }
  }

  bool undo() {
    _stroke?.commit();
    if (_undo.isEmpty) return false;
    final command = _undo.removeLast()..undo(document);
    _bytes -= command.weight;
    _redo.add(command);
    return true;
  }

  bool redo() {
    _stroke?.commit();
    if (_redo.isEmpty) return false;
    final command = _redo.removeLast()..redo(document);
    _bytes += command.weight;
    _undo.add(command);
    return true;
  }
}
