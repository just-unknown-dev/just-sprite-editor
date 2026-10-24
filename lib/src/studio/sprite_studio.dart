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
import 'studio_files.dart';
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
    this.pickFile,
  });

  /// Project-relative file to open.
  final String? path;

  /// How Import… asks for a file from outside the project: the system's
  /// Open dialog when null. Null back when nothing was chosen.
  final Future<String?> Function()? pickFile;

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

  int _libraryTicket = 0;

  /// Looks through the project for its sprites, away from the UI thread;
  /// the list fills in when that is done.
  void _refreshLibrary() {
    if (!mounted) return;
    final ticket = ++_libraryTicket;
    _sprites.scanInBackground().then((found) {
      if (mounted && ticket == _libraryTicket) {
        setState(() => _library = found);
      }
    }, onError: (Object _) {});
  }

  static String _describe(Object e) => e is FormatException ? e.message : '$e';

  /// Says what went wrong: over the sprite that is open, or — with none
  /// open — in its place.
  void _showProblem(String text) {
    if (!mounted) return;
    if (_session == null) {
      setState(() => _error = text);
    } else {
      _showToast(text);
    }
  }

  /// Opens a sprite the project already holds. False when it did not:
  /// the artist kept what was open, or the file could not be read (which
  /// it says).
  Future<bool> _openPath(String path) async {
    if (_session?.path == path) return true;
    if (!await _mayDiscard()) return false;
    try {
      _adopt(
        await SpriteStudioSession.open(
          path,
          root: widget.root,
          decodeImage: pixelsFromImageBytes,
        ),
      );
      return true;
    } catch (e) {
      _showProblem('Could not open ${path.split('/').last}: ${_describe(e)}');
      return false;
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
    final picked = await (widget.pickFile ?? pickSpriteFile)();
    if (picked == null || !mounted) return;
    final String copied;
    try {
      copied = await _sprites.import(picked, into: widget.newSpriteFolder);
    } catch (e) {
      _showProblem('Could not import: ${_describe(e)}');
      return;
    }
    // Kept what was open, or the file would not open: nothing came of it,
    // so the copy goes again.
    if (!await _openPath(copied)) {
      try {
        await File('${_sprites.root}/$copied').delete();
      } on FileSystemException {
        // Already gone.
      }
      return;
    }
    final s = _session;
    if (s == null || !mounted) return;
    // Too big to save until it is sliced: what the session said stays up.
    if (!s.document.fitsForSaving) return;
    if (!copied.toLowerCase().endsWith('.$kProjectExtension')) {
      // The copy has a name of its own: nothing to ask about.
      await save(askBeforeReplacing: false);
    }
    _refreshLibrary();
    _showToast('Imported ${copied.split('/').last}');
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
    // A sheet bigger than a sprite can be saved: cutting it into frames is
    // the way on, so that is offered straight away.
    if (!next.document.fitsForSaving) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _session == next) _sliceIntoFrames();
      });
    }
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

  /// Saves the sprite: asks a new one for a name first — one no file has
  /// yet — and asks before writing over files this sprite did not write
  /// ([SpriteStudioSession.filesInTheWay]) unless [askBeforeReplacing] is
  /// off.
  Future<void> save({bool askBeforeReplacing = true}) async {
    final s = _session;
    if (s == null) return;
    if (!s.document.fitsForSaving) return _showToast(s.tooBigToSaveMessage);
    var target = s.path;
    if (target == null) {
      final name = await promptForText(
        context,
        title: 'Name this sprite',
        initial: freeStem(
          '${_sprites.root}/${widget.newSpriteFolder}',
          'sprite',
          const ['.$kProjectExtension', '.png', '.json'],
        ),
      );
      if (name == null || name.isEmpty || !mounted) return;
      target = '${widget.newSpriteFolder}/${safeFileName(name)}.jsprite';
    }
    if (askBeforeReplacing) {
      final inTheWay = await s.filesInTheWay(target);
      if (inTheWay.isNotEmpty && !await _mayReplace(inTheWay)) return;
    }
    try {
      final saved = await s.save(to: target);
      widget.onSaved?.call(saved);
      if (mounted) setState(() {});
    } catch (e) {
      _showToast('Could not save: ${_describe(e)}');
    }
  }

  /// Whether saving may write over [files] (project-relative), which this
  /// sprite did not write.
  Future<bool> _mayReplace(List<String> files) async {
    if (!mounted) return false;
    final names = [for (final f in files) f.split('/').last];
    final project = names.where((n) => n.endsWith('.$kProjectExtension'));
    final list = names.length == 1
        ? names.single
        : '${names.sublist(0, names.length - 1).join(', ')} and '
              '${names.last}';
    final stem = names.first.substring(0, names.first.lastIndexOf('.'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: StudioTheme.panel,
        title: Text(
          project.isNotEmpty ? 'Replace ${project.first}?' : 'Save over $list?',
          style: StudioTheme.body.copyWith(fontSize: 13),
        ),
        content: Text(
          project.isNotEmpty
              ? 'Another sprite is saved there. Saving writes over $list, '
                    'and that cannot be undone.'
              : '$list ${names.length == 1 ? 'is' : 'are'} already there, '
                    'and this sprite did not write '
                    '${names.length == 1 ? 'it' : 'them'}. Saving puts this '
                    "sprite's sheet and atlas there; what was there is kept "
                    'as $stem.original.png / $stem.original.json.',
          style: StudioTheme.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(project.isNotEmpty ? 'Replace' : 'Save'),
          ),
        ],
      ),
    );
    return ok ?? false;
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
  /// one image. One undo step; only for a one-frame sprite.
  Future<void> _sliceIntoFrames() async {
    final s = _session!;
    if (s.document.frames.length > 1) {
      return s.say('Slicing cuts a one-frame picture: an imported sheet.');
    }
    final side = s.document.height.clamp(1, SpriteDocument.maxSize);
    final size = await _promptForSize(
      context,
      'Slice into frames — size of one frame',
      side,
      side,
    );
    if (size == null || !mounted || _session != s) return;
    final n = s.sliceIntoFrames(size.$1, size.$2);
    s.say('$n frames. Tag runs of them as clips.');
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
    // A key that edits the sprite, or moves off the frame, while a stroke
    // is being drawn: the stroke ends there, as one step, so that nothing
    // drawn after the key lands outside the history.
    void endStroke() => _canvas.currentState?.endGesture();

    if (ctrl) {
      if (event is KeyRepeatEvent &&
          key != LogicalKeyboardKey.keyZ &&
          key != LogicalKeyboardKey.keyY) {
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyS) {
        endStroke();
        save();
      } else if (key == LogicalKeyboardKey.keyZ) {
        endStroke();
        shift ? s.redo() : s.undo();
      } else if (key == LogicalKeyboardKey.keyY) {
        endStroke();
        s.redo();
      } else if (key == LogicalKeyboardKey.keyA) {
        endStroke();
        StudioActions.selectAll(s);
      } else if (key == LogicalKeyboardKey.keyD) {
        endStroke();
        s.selection.value = null;
      } else if (key == LogicalKeyboardKey.keyN) {
        endStroke();
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
      endStroke();
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
      endStroke();
      s.stepFrame(-1);
    } else if (key == LogicalKeyboardKey.period ||
        key == LogicalKeyboardKey.arrowRight) {
      endStroke();
      s.stepFrame(1);
    } else if (key == LogicalKeyboardKey.enter) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      endStroke();
      s.togglePlay();
    } else if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add) {
      s.zoomBy(1);
    } else if (key == LogicalKeyboardKey.minus) {
      s.zoomBy(-1);
    } else if (EditorKeys.isDeleteKey(key)) {
      // Delete, and the Mac's delete key (Backspace), as across the editor.
      endStroke();
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
      signal: s.structureRevision,
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
            tooltip: s.document.frames.length == 1
                ? 'Slice this picture into frames (an imported sheet)'
                : 'Slice into frames: for a one-frame picture, such as an '
                      'imported sheet',
            onTap: s.document.frames.length == 1
                ? state._sliceIntoFrames
                : null,
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
  final typed = await showDialog<(String, String)>(
    context: context,
    builder: (context) =>
        _SizeDialog(title: title, width: width, height: height),
  );
  if (typed == null) return null;
  final width_ = int.tryParse(typed.$1.trim()) ?? 0;
  final height_ = int.tryParse(typed.$2.trim()) ?? 0;
  if (width_ < 1 ||
      height_ < 1 ||
      width_ > SpriteDocument.maxSize ||
      height_ > SpriteDocument.maxSize) {
    return null;
  }
  return (width_, height_);
}

/// The width-and-height dialog. It owns its fields' controllers, so they
/// go when it does — after its closing animation, not before.
class _SizeDialog extends StatefulWidget {
  const _SizeDialog({
    required this.title,
    required this.width,
    required this.height,
  });

  final String title;
  final int width;
  final int height;

  @override
  State<_SizeDialog> createState() => _SizeDialogState();
}

class _SizeDialogState extends State<_SizeDialog> {
  late final TextEditingController _w = TextEditingController(
    text: '${widget.width}',
  );
  late final TextEditingController _h = TextEditingController(
    text: '${widget.height}',
  );

  @override
  void dispose() {
    _w.dispose();
    _h.dispose();
    super.dispose();
  }

  void _done() => Navigator.of(context).pop((_w.text, _h.text));

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: StudioTheme.panel,
    title: Text(widget.title, style: StudioTheme.body.copyWith(fontSize: 13)),
    content: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 80,
          child: TextField(
            controller: _w,
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
            controller: _h,
            style: StudioTheme.body,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Height'),
            onSubmitted: (_) => _done(),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(onPressed: _done, child: const Text('OK')),
    ],
  );
}
