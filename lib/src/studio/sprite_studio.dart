import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_editor_core/just_editor_core.dart' show EditorKeys;
import 'package:just_signals/just_signals.dart';

import '../document/io/sheet_export.dart';
import '../document/palettes.dart';
import '../document/sprite_document.dart';
import 'studio_canvas.dart';
import 'studio_library.dart';
import 'studio_panels.dart';
import 'studio_session.dart';
import 'studio_theme.dart';
import 'studio_timeline.dart';
import 'studio_tools.dart';

/// The sprite editor: canvas, tools, colour, layers and the frame timeline.
///
/// Give it a [path] to open — a `.jsprite` project or an image — or none for
/// a new sprite. It runs by itself; inside the game editor it is the body of
/// a workspace.
class SpriteStudio extends StatefulWidget {
  const SpriteStudio({
    super.key,
    this.path,
    this.root,
    this.newSpriteFolder = 'assets/sprites',
    this.onClose,
    this.onSaved,
    this.fullScreen,
    this.onToggleFullScreen,
    this.setCloseGuard,
  });

  /// Project-relative file to open.
  final String? path;

  /// The project root; the working directory when null.
  final String? root;

  /// Where a new sprite is saved the first time.
  final String newSpriteFolder;

  final VoidCallback? onClose;

  /// Called after each save with what was written, so a host can show the
  /// new sheet.
  final void Function(SavedSprite saved)? onSaved;

  /// Whether the host is showing this filling the editor; null where there
  /// is no such choice.
  final ValueListenable<bool>? fullScreen;

  /// Switches between a dialog over the editor and filling it.
  final VoidCallback? onToggleFullScreen;

  /// Where to leave the question a host asks before it opens something
  /// else over the studio: whether the unsaved work may go. Null clears it.
  final void Function(Future<bool> Function()? guard)? setCloseGuard;

  @override
  State<SpriteStudio> createState() => SpriteStudioState();
}

class SpriteStudioState extends State<SpriteStudio> {
  SpriteStudioSession? _session;
  String? _error;
  final FocusNode _focus = FocusNode(debugLabel: 'SpriteStudio');
  final GlobalKey<StudioCanvasState> _canvas = GlobalKey();
  VoidCallback? _stopMessages;
  String? _toast;
  Timer? _toastTimer;

  /// The open session, for a host or a test.
  SpriteStudioSession? get session => _session;

  @override
  void initState() {
    super.initState();
    widget.setCloseGuard?.call(_mayDiscard);
    _open();
    _refreshLibrary();
  }

  /// The project's own sprites, for the panel beside the canvas.
  List<SpriteAsset> _library = const [];
  bool _libraryOpen = true;
  double _libraryHeight = SpriteLibraryPanel.defaultHeight;

  /// Grows or shrinks the list, within what leaves room for the colour
  /// and the layers below it.
  void _resizeLibrary(double dy) {
    final room = MediaQuery.sizeOf(context).height - 360;
    setState(() {
      _libraryHeight = (_libraryHeight + dy).clamp(
        SpriteLibraryPanel.minHeight,
        room < SpriteLibraryPanel.minHeight
            ? SpriteLibraryPanel.minHeight
            : room,
      );
    });
  }

  late final SpriteLibrary _sprites = SpriteLibrary(
    root: (widget.root ?? Directory.current.path).replaceAll('\\', '/'),
  );

  /// Shows or hides the list beside the canvas; looking again when it
  /// comes back, since a sprite may have been made elsewhere meanwhile.
  void _toggleLibrary() {
    setState(() => _libraryOpen = !_libraryOpen);
    if (_libraryOpen) _refreshLibrary();
  }

  void _refreshLibrary() {
    if (!mounted) return;
    setState(() => _library = _sprites.scan());
  }

  /// Opens a sprite the project already holds.
  Future<void> _openPath(String path) async {
    if (_session?.path == path) return;
    if (!await _mayDiscard()) return;
    try {
      _adopt(
        await SpriteStudioSession.open(
          path,
          root: widget.root,
          decodeImage: pixelsFromImageBytes,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Brings a sprite in from outside.
  ///
  /// Copied into the project, because a sprite the project does not hold
  /// is one the game cannot load — and, when what was picked is an image
  /// rather than a project, saved as one straight away so that it joins
  /// the list instead of waiting on a first save. The image it came from
  /// is kept beside it as the original art.
  Future<void> _import() async {
    final picked = await pickSpriteFile();
    if (picked == null) return;
    try {
      final copied = await _sprites.import(
        picked,
        into: widget.newSpriteFolder,
      );
      await _openPath(copied);
      if (!copied.toLowerCase().endsWith('.$kProjectExtension') &&
          _session != null) {
        await save();
      }
      _refreshLibrary();
      _showToast('Imported ${copied.split('/').last}');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _open() async {
    try {
      final path = widget.path;
      _adopt(
        path == null
            ? SpriteStudioSession(
                SpriteDocument.blank(32, 32, palette: Palettes.db32.colors),
                root: widget.root,
              )
            : await SpriteStudioSession.open(
                path,
                root: widget.root,
                decodeImage: pixelsFromImageBytes,
              ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _adopt(SpriteStudioSession next) {
    if (!mounted) return next.dispose();
    _stopMessages?.call();
    _session?.dispose();
    _stopMessages = next.message.watch(() => _showToast(next.message.value));
    setState(() {
      _session = next;
      _error = null;
    });
    if (next.message.value != null) _showToast(next.message.value);
  }

  void _showToast(String? text) {
    if (!mounted || text == null) return;
    _toastTimer?.cancel();
    setState(() => _toast = text);
    _toastTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  @override
  void dispose() {
    widget.setCloseGuard?.call(null);
    _toastTimer?.cancel();
    _stopMessages?.call();
    _session?.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ── Commands ─────────────────────────────────────────────────────────────

  Future<void> save() async {
    final s = _session;
    if (s == null) return;
    var target = s.path;
    if (target == null) {
      final name = await promptForText(
        context,
        title: 'Name this sprite',
        initial: 'sprite',
      );
      if (name == null || name.isEmpty) return;
      final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_');
      target = '${widget.newSpriteFolder}/$safe.jsprite';
    }
    try {
      final saved = await s.save(to: target);
      widget.onSaved?.call(saved);
      if (mounted) setState(() {});
    } catch (e) {
      _showToast('Could not save: $e');
    }
  }

  Future<void> _newSprite() async {
    if (!await _mayDiscard()) return;
    if (!mounted) return;
    final size = await _promptForSize(context, 'New sprite', 32, 32);
    if (size == null) return;
    _adopt(
      SpriteStudioSession(
        SpriteDocument.blank(size.$1, size.$2, palette: Palettes.db32.colors),
        root: widget.root,
      ),
    );
  }

  Future<void> _canvasSize() async {
    final s = _session!;
    final size = await _promptForSize(
      context,
      'Canvas size',
      s.document.width,
      s.document.height,
    );
    if (size == null) return;
    // Grows and shrinks about the middle, so a character stays centred.
    final dx = (size.$1 - s.document.width) ~/ 2;
    final dy = (size.$2 - s.document.height) ~/ 2;
    s.structural(
      'Canvas size',
      (d) => d.resizeCanvas(size.$1, size.$2, dx: dx, dy: dy),
    );
  }

  /// Cuts the current picture into frames: for a sheet that was opened as
  /// one image.
  Future<void> _sliceIntoFrames() async {
    final s = _session!;
    final size = await _promptForSize(
      context,
      'Slice into frames — size of one frame',
      s.document.height,
      s.document.height,
    );
    if (size == null) return;
    final sliced = SheetImporter.fromSheet(
      s.document.flatten(s.frameIndex.value),
      frameWidth: size.$1,
      frameHeight: size.$2,
    )..palette.addAll(s.document.palette);
    final next = SpriteStudioSession(sliced, path: s.path, root: s.root)
      ..say('${sliced.frames.length} frames. Tag runs of them as clips.');
    _adopt(next);
  }

  Future<void> _exportGif() async {
    final s = _session!;
    if (s.path == null) await save();
    if (s.path == null) return;
    try {
      await s.exportGif();
    } catch (e) {
      _showToast('Could not export: $e');
    }
  }

  /// True when it is fine to lose what is open: nothing unsaved, or the
  /// artist said so.
  Future<bool> _mayDiscard() async {
    final s = _session;
    if (s == null || !s.isDirty) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: StudioTheme.panel,
        title: Text(
          'Save changes to ${s.path?.split('/').last ?? 'this sprite'}?',
          style: StudioTheme.body.copyWith(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('discard'),
            child: Text(
              "Don't save",
              style: TextStyle(color: StudioTheme.danger),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (choice == 'save') {
      await save();
      return !(_session?.isDirty ?? false);
    }
    return choice == 'discard';
  }

  Future<void> close() async {
    if (await _mayDiscard()) widget.onClose?.call();
  }

  // ── Keys ─────────────────────────────────────────────────────────────────

  static bool get _isTyping {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final s = _session;
    if (s == null || event is KeyUpEvent || _isTyping) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keys = HardwareKeyboard.instance;
    final ctrl = EditorKeys.primaryPressed;
    final shift = keys.isShiftPressed;

    if (ctrl) {
      if (event is KeyRepeatEvent &&
          key != LogicalKeyboardKey.keyZ &&
          key != LogicalKeyboardKey.keyY) {
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyS) {
        save();
      } else if (key == LogicalKeyboardKey.keyZ) {
        shift ? s.redo() : s.undo();
      } else if (key == LogicalKeyboardKey.keyY) {
        s.redo();
      } else if (key == LogicalKeyboardKey.keyA) {
        StudioActions.selectAll(s);
      } else if (key == LogicalKeyboardKey.keyD) {
        s.selection.value = null;
      } else if (key == LogicalKeyboardKey.keyN) {
        _newSprite();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    // The modifier no shortcut is made with (Ctrl on a Mac): a letter with
    // it is not the bare letter's tool.
    if (EditorKeys.otherPressed) return KeyEventResult.ignored;

    if (keys.isAltPressed && key == LogicalKeyboardKey.keyN) {
      s.addFrame();
      return KeyEventResult.handled;
    }
    for (final tool in StudioTool.values) {
      if (key.keyLabel.toUpperCase() == tool.key && event is KeyDownEvent) {
        s.tool.value = tool;
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.keyX) {
      s.swapColors();
    } else if (key == LogicalKeyboardKey.bracketLeft) {
      s.brushSize.value = (s.brushSize.value - 1).clamp(1, 32);
    } else if (key == LogicalKeyboardKey.bracketRight) {
      s.brushSize.value = (s.brushSize.value + 1).clamp(1, 32);
    } else if (key == LogicalKeyboardKey.comma ||
        key == LogicalKeyboardKey.arrowLeft) {
      s.stepFrame(-1);
    } else if (key == LogicalKeyboardKey.period ||
        key == LogicalKeyboardKey.arrowRight) {
      s.stepFrame(1);
    } else if (key == LogicalKeyboardKey.enter) {
      s.togglePlay();
    } else if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add) {
      s.zoomBy(1);
    } else if (key == LogicalKeyboardKey.minus) {
      s.zoomBy(-1);
    } else if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      StudioActions.deletePixels(s);
    } else if (key == LogicalKeyboardKey.escape) {
      if (!(_canvas.currentState?.cancelGesture() ?? false)) {
        s.selection.value = null;
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = _session;
    if (s == null) {
      return ColoredBox(
        color: StudioTheme.background,
        child: Center(
          child: _error == null
              ? const CircularProgressIndicator(strokeWidth: 2)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, style: StudioTheme.body),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: widget.onClose,
                      child: const Text('Close'),
                    ),
                  ],
                ),
        ),
      );
    }
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        // A click anywhere that is not a text field brings the keys back.
        onPointerDown: (_) {
          if (!_isTyping) _focus.requestFocus();
        },
        child: Material(
          color: StudioTheme.background,
          child: Column(
            children: [
              _TopBar(state: this, session: s),
              ToolOptionsBar(session: s),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ToolStrip(session: s),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: StudioCanvas(key: _canvas, session: s),
                          ),
                          if (_toast != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 12,
                              child: Center(child: _Toast(_toast!)),
                            ),
                        ],
                      ),
                    ),
                    Container(
                      width: 232,
                      decoration: BoxDecoration(
                        color: StudioTheme.panel,
                        border: Border(
                          left: BorderSide(color: StudioTheme.border),
                        ),
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SpriteLibraryPanel(
                              assets: _library,
                              openPath: s.path,
                              onOpen: (asset) => _openPath(asset.path),
                              onImport: _import,
                              onRefresh: _refreshLibrary,
                              isOpen: _libraryOpen,
                              onToggle: _toggleLibrary,
                              height: _libraryHeight,
                              onResize: _resizeLibrary,
                            ),
                            ColorPanel(session: s),
                            LayersPanel(session: s),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: StudioTheme.border),
              SizedBox(height: 176, child: TimelinePanel(session: s)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.state, required this.session});

  final SpriteStudioState state;
  final SpriteStudioSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return SignalBuilder<int>(
      signal: s.revision,
      builder: (context, _, _) => StudioHeader(
        icon: Icons.brush,
        title: 'Sprite Studio',
        file: s.fileName,
        detail: '${s.document.width} × ${s.document.height}',
        dirty: s.isDirty,
        onSave: state.save,
        saveTooltip: 'Save — the project, and the sheet + atlas the game loads',
        onUndo: s.editor.canUndo ? s.undo : null,
        onRedo: s.editor.canRedo ? s.redo : null,
        undoLabel: s.editor.undoLabel,
        redoLabel: s.editor.redoLabel,
        fullScreen: state.widget.fullScreen,
        onToggleFullScreen: state.widget.onToggleFullScreen,
        onClose: state.widget.onClose == null ? null : state.close,
        closeTooltip: 'Close the studio',
        tools: [
          StudioIconButton(
            icon: Icons.note_add_outlined,
            tooltip: 'New sprite  (${EditorKeys.withPrimary('N')})',
            onTap: state._newSprite,
          ),
          const SizedBox(width: 8),
          StudioIconButton(
            icon: Icons.flip,
            tooltip: 'Flip horizontal (selection or cel)',
            onTap: () => StudioActions.flip(s, horizontal: true),
          ),
          StudioIconButton(
            icon: Icons.flip_camera_android,
            tooltip: 'Flip vertical (selection or cel)',
            onTap: () => StudioActions.flip(s, horizontal: false),
          ),
          StudioIconButton(
            icon: Icons.rotate_90_degrees_cw_outlined,
            tooltip: 'Rotate 90° (selection or cel)',
            onTap: () => StudioActions.rotate(s),
          ),
          StudioIconButton(
            icon: Icons.find_replace,
            tooltip: 'Replace the primary colour with the secondary',
            onTap: () => StudioActions.replaceColor(s),
          ),
          const SizedBox(width: 8),
          StudioIconButton(
            icon: Icons.aspect_ratio,
            tooltip: 'Canvas size',
            onTap: state._canvasSize,
          ),
          StudioIconButton(
            icon: Icons.crop,
            tooltip: 'Crop to the selection',
            onTap: () => StudioActions.cropToSelection(s),
          ),
          StudioIconButton(
            icon: Icons.view_module_outlined,
            tooltip: 'Slice this picture into frames (an imported sheet)',
            onTap: state._sliceIntoFrames,
          ),
          const SizedBox(width: 8),
          _ExportOptionsButton(session: s),
          StudioIconButton(
            icon: Icons.gif_box_outlined,
            tooltip:
                'Export a GIF of the tag being played (or every frame), '
                'beside the sprite',
            onTap: state._exportGif,
          ),
        ],
      ),
    );
  }
}

/// How the sheet the game loads is laid out. Applies from the next save.
class _ExportOptionsButton extends StatelessWidget {
  const _ExportOptionsButton({required this.session});

  final SpriteStudioSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final now = s.document.exportOptions;
    void set(SheetExportOptions next) => s
      ..structural('Export options', (d) => d.exportOptions = next)
      ..say('The sheet will be laid out that way on the next save.');

    return PopupMenuButton<VoidCallback>(
      tooltip: 'Sheet export options',
      color: StudioTheme.panelRaised,
      padding: EdgeInsets.zero,
      icon: Icon(Icons.tune, size: 15, color: StudioTheme.text),
      onSelected: (apply) => apply(),
      itemBuilder: (context) => [
        for (final layout in SheetLayout.values)
          CheckedPopupMenuItem(
            value: () => set(now.copyWith(layout: layout)),
            checked: now.layout == layout,
            height: 30,
            child: Text('Layout: ${layout.name}', style: StudioTheme.body),
          ),
        const PopupMenuDivider(),
        for (final padding in const [0, 1, 2])
          CheckedPopupMenuItem(
            value: () => set(now.copyWith(padding: padding)),
            checked: now.padding == padding,
            height: 30,
            child: Text(
              padding == 0 ? 'No padding' : 'Padding: $padding px',
              style: StudioTheme.body,
            ),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: () => set(now.copyWith(trim: !now.trim)),
          checked: now.trim,
          height: 30,
          child: Text('Trim frames to their content', style: StudioTheme.body),
        ),
        for (final scale in const [1, 2, 4])
          CheckedPopupMenuItem(
            value: () => set(now.copyWith(scale: scale)),
            checked: now.scale == scale,
            height: 30,
            child: Text('Scale: $scale×', style: StudioTheme.body),
          ),
      ],
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: StudioTheme.panelRaised,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: StudioTheme.border),
    ),
    child: Text(text, style: StudioTheme.body),
  );
}

/// Asks for a width and a height. Null when cancelled or not a size.
Future<(int, int)?> _promptForSize(
  BuildContext context,
  String title,
  int width,
  int height,
) async {
  final w = TextEditingController(text: '$width');
  final h = TextEditingController(text: '$height');
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: StudioTheme.panel,
      title: Text(title, style: StudioTheme.body.copyWith(fontSize: 13)),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 80,
            child: TextField(
              controller: w,
              autofocus: true,
              style: StudioTheme.body,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Width'),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('×', style: StudioTheme.body),
          ),
          SizedBox(
            width: 80,
            child: TextField(
              controller: h,
              style: StudioTheme.body,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Height'),
              onSubmitted: (_) => Navigator.of(context).pop(true),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  if (ok != true) return null;
  final width_ = int.tryParse(w.text.trim()) ?? 0;
  final height_ = int.tryParse(h.text.trim()) ?? 0;
  if (width_ < 1 ||
      height_ < 1 ||
      width_ > SpriteDocument.maxSize ||
      height_ > SpriteDocument.maxSize) {
    return null;
  }
  return (width_, height_);
}
