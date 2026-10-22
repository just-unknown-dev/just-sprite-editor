import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_game_engine/just_game_engine.dart';
import 'package:just_editor_core/just_editor_core.dart'
    show CommitTextField;
import 'package:just_signals/just_signals.dart';

import '../studio_panels.dart';
import '../studio_theme.dart';
import 'animator_session.dart';

/// The animation state machine, as a graph: states are nodes, transitions
/// are arrows, and the side panel edits whichever is selected.
class AnimatorGraphEditor extends StatefulWidget {
  const AnimatorGraphEditor({
    super.key,
    this.path,
    this.root,
    this.newGraphFolder = 'assets/sprites',
    this.onClose,
    this.onSaved,
    this.liveState,
    this.fullScreen,
    this.onToggleFullScreen,
    this.setCloseGuard,
    this.bindings,
  });

  /// Project-relative `.animator.json` to open; none starts a new graph.
  final String? path;
  final String? root;
  final String newGraphFolder;
  final VoidCallback? onClose;
  final void Function(String path)? onSaved;

  /// The state a running game is in for the graph at the given path, or
  /// null when nothing is running it. Polled, to light the live node.
  final String? Function(String graphPath)? liveState;

  /// Whether the host is showing this filling the editor; null where there
  /// is no such choice.
  final ValueListenable<bool>? fullScreen;

  /// Switches between a dialog over the editor and filling it.
  final VoidCallback? onToggleFullScreen;

  /// Where to leave the question a host asks before it opens something
  /// else over this one: whether the unsaved work may go. Null clears it.
  final void Function(Future<bool> Function()? guard)? setCloseGuard;

  /// What a parameter can be bound to: the edited engine's
  /// (`context.animatorBindings`). The engine's own when null.
  final AnimatorBindings? bindings;

  @override
  State<AnimatorGraphEditor> createState() => AnimatorGraphEditorState();
}

class AnimatorGraphEditorState extends State<AnimatorGraphEditor> {
  AnimatorGraphSession? _session;
  String? _error;
  final FocusNode _focus = FocusNode(debugLabel: 'AnimatorGraphEditor');
  Timer? _livePoll;
  String? _live;
  String? _toast;
  Timer? _toastTimer;
  VoidCallback? _stopMessages;

  /// A transition being drawn: the node it starts from.
  String? _linkFrom;
  Offset _pan = const Offset(40, 30);

  AnimatorGraphSession? get session => _session;

  static const Size nodeSize = Size(132, 44);
  static const String entryNode = '\u0000entry';

  @override
  void initState() {
    super.initState();
    widget.setCloseGuard?.call(_mayLeave);
    _open();
    if (widget.liveState != null) {
      _livePoll = Timer.periodic(const Duration(milliseconds: 120), (_) {
        final path = _session?.path;
        final now = path == null ? null : widget.liveState!(path);
        if (now != _live && mounted) setState(() => _live = now);
      });
    }
  }

  Future<void> _open() async {
    try {
      final path = widget.path;
      final s = path == null
          ? AnimatorGraphSession(
              const AnimatorGraph(),
              root: widget.root,
              bindings: widget.bindings,
            )
          : await AnimatorGraphSession.open(
              path,
              root: widget.root,
              bindings: widget.bindings,
            );
      if (!mounted) return s.dispose();
      _stopMessages = s.message.watch(() => _showToast(s.message.value));
      setState(() => _session = s);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open the graph: $e');
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
    _livePoll?.cancel();
    _toastTimer?.cancel();
    _stopMessages?.call();
    _session?.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final s = _session;
    if (s == null) return;
    var target = s.path;
    if (target == null) {
      final name = await promptForText(
        context,
        title: 'Name this animator',
        initial: 'character',
      );
      if (name == null || name.isEmpty) return;
      final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_');
      target =
          '${widget.newGraphFolder}/$safe.${AnimatorGraphSession.extension}';
    }
    try {
      widget.onSaved?.call(await s.save(to: target));
    } catch (e) {
      _showToast('Could not save: $e');
    }
  }

  /// Whether it is fine to go: nothing unsaved, or the author said what
  /// to do with it — and if that was Save, it saved.
  Future<bool> _mayLeave() async {
    final s = _session;
    if (s == null || !s.isDirty) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: StudioTheme.panel,
        title: Text(
          'Save changes to this animator?',
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
    if (await _mayLeave()) widget.onClose?.call();
  }

  static bool get _isTyping {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final s = _session;
    if (s == null || event is! KeyDownEvent || _isTyping) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed || keys.isMetaPressed;
    final key = event.logicalKey;
    if (ctrl && key == LogicalKeyboardKey.keyS) {
      save();
    } else if (ctrl && key == LogicalKeyboardKey.keyZ) {
      keys.isShiftPressed ? s.redo() : s.undo();
    } else if (ctrl && key == LogicalKeyboardKey.keyY) {
      s.redo();
    } else if (key == LogicalKeyboardKey.escape) {
      setState(() => _linkFrom = null);
      s.selection.value = null;
    } else if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      final sel = s.selection.value;
      if (sel?.state != null) s.removeState(sel!.state!);
      if (sel?.transition != null) s.removeTransition(sel!.transition!);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ── Geometry ─────────────────────────────────────────────────────────────

  /// Where a node sits on the canvas, before panning. Entry and Any State
  /// are fixed at the left; states are where the author put them.
  Rect rectOf(String node, AnimatorGraph g) {
    if (node == entryNode) return const Offset(16, 24) & const Size(84, 30);
    if (node == AnimatorTransition.anyState) {
      return const Offset(16, 96) & const Size(84, 30);
    }
    final s = g.stateNamed(node);
    return Offset(s?.x ?? 0, s?.y ?? 0) & nodeSize;
  }

  void _tapNode(String node) {
    final s = _session!;
    final from = _linkFrom;
    if (from != null) {
      setState(() => _linkFrom = null);
      if (node != entryNode && node != AnimatorTransition.anyState) {
        if (from == entryNode) {
          s.setEntry(node);
        } else {
          s.addTransition(from, node);
        }
      }
      return;
    }
    if (node != entryNode && node != AnimatorTransition.anyState) {
      s.selection.value = GraphSelection.state(node);
    }
  }

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
        onPointerDown: (_) {
          if (!_isTyping) _focus.requestFocus();
        },
        child: Material(
          color: StudioTheme.background,
          child: SignalConsumer(
            signals: [s.graph, s.selection],
            builder: (context, _) => Column(
              children: [
                _bar(s),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 250, child: _ParametersPanel(session: s)),
                      VerticalDivider(width: 1, color: StudioTheme.border),
                      Expanded(child: _canvas(s)),
                      VerticalDivider(width: 1, color: StudioTheme.border),
                      SizedBox(
                        width: 280,
                        child: _Inspector(
                          key: ValueKey(s.selection.value),
                          session: s,
                          clips: s.readClipNames(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar(AnimatorGraphSession s) {
    final problems = s.g.validate();
    return StudioHeader(
      icon: Icons.account_tree_outlined,
      title: 'Animator',
      file: s.fileName,
      dirty: s.isDirty,
      onSave: save,
      onUndo: s.canUndo ? s.undo : null,
      onRedo: s.canRedo ? s.redo : null,
      fullScreen: widget.fullScreen,
      onToggleFullScreen: widget.onToggleFullScreen,
      onClose: widget.onClose == null ? null : close,
      tools: [
        Text('Clips from', style: StudioTheme.label),
        const SizedBox(width: 6),
        SizedBox(
          width: 260,
          height: 24,
          child: _TextBox(
            key: ValueKey('atlas:${s.g.atlasPath}'),
            value: s.g.atlasPath,
            hint: 'an atlas (hero.json) or a 3D model (hero.glb)',
            onSubmitted: (v) => s.apply(s.g.copyWith(atlasPath: v.trim())),
          ),
        ),
        StudioIconButton(
          icon: Icons.auto_awesome_motion_outlined,
          tooltip: 'Add a state for every clip in the atlas or model',
          onTap: () {
            final n = s.addStatesForClips(s.readClipNames());
            s.say(
              n == 0
                  ? 'No new clips found. Is the atlas path right?'
                  : 'Added $n states.',
            );
          },
        ),
      ],
      trailing: [
        if (_live != null)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(
              '● LIVE  $_live',
              style: StudioTheme.label.copyWith(color: const Color(0xFF7DE6B1)),
            ),
          ),
        if (problems.isNotEmpty)
          Tooltip(
            message: problems.join('\n'),
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: StudioTheme.warning,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${problems.length}',
                    style: StudioTheme.label.copyWith(
                      color: StudioTheme.warning,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _canvas(AnimatorGraphSession s) {
    final g = s.g;
    final nodes = [
      entryNode,
      AnimatorTransition.anyState,
      for (final state in g.states) state.name,
    ];
    return ClipRect(
      child: Stack(
        children: [
          // The background: pans the graph, and a double-click adds a state.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => setState(() => _pan += d.delta),
              onTapUp: (d) {
                final hit = _transitionAt(d.localPosition - _pan, g);
                setState(() => _linkFrom = null);
                s.selection.value = hit == null
                    ? null
                    : GraphSelection.transition(hit);
              },
              onDoubleTapDown: (d) {
                final at = d.localPosition - _pan;
                s.addState(
                  at.dx - nodeSize.width / 2,
                  at.dy - nodeSize.height / 2,
                );
              },
              child: CustomPaint(
                painter: _ArrowPainter(
                  graph: g,
                  pan: _pan,
                  rectOf: (n) => rectOf(n, g),
                  selected: s.selection.value?.transition,
                ),
              ),
            ),
          ),
          for (final node in nodes) _node(s, node),
          Positioned(
            left: 12,
            bottom: 10,
            child: Text(
              _linkFrom != null
                  ? 'Click the state this leads to  ·  Esc to cancel'
                  : 'Double-click to add a state  ·  drag to arrange  ·  '
                        'the arrow button on a node starts a transition',
              style: StudioTheme.label,
            ),
          ),
          if (_toast != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 34,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: StudioTheme.panelRaised,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: StudioTheme.border),
                  ),
                  child: Text(_toast!, style: StudioTheme.body),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _node(AnimatorGraphSession s, String node) {
    final g = s.g;
    final rect = rectOf(node, g).shift(_pan);
    final isSpecial = node == entryNode || node == AnimatorTransition.anyState;
    final state = isSpecial ? null : g.stateNamed(node);
    final selected = s.selection.value?.state == node;
    final live = _live != null && _live == node;
    final linking = _linkFrom == node;
    final color = node == entryNode
        ? const Color(0xFF7DE6B1)
        : node == AnimatorTransition.anyState
        ? const Color(0xFF6FA8F5)
        : StudioTheme.accent;
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        onTap: () => _tapNode(node),
        onPanUpdate: state == null
            ? null
            : (d) => s.moveState(
                node,
                state.x + d.delta.dx,
                state.y + d.delta.dy,
                commit: false,
              ),
        onPanEnd: state == null
            ? null
            : (_) {
                final now = s.g.stateNamed(node)!;
                s.moveState(node, now.x, now.y, commit: true);
              },
        child: Container(
          decoration: BoxDecoration(
            color: live
                ? const Color(0xFF1F4A36)
                : selected
                ? StudioTheme.selected
                : StudioTheme.panelRaised,
            borderRadius: BorderRadius.circular(isSpecial ? 15 : 7),
            border: Border.all(
              color: live
                  ? const Color(0xFF7DE6B1)
                  : selected || linking
                  ? color
                  : StudioTheme.border,
              width: live || selected || linking ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.only(left: 10, right: 2),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node == entryNode
                          ? 'Entry'
                          : node == AnimatorTransition.anyState
                          ? 'Any State'
                          : node,
                      overflow: TextOverflow.ellipsis,
                      style: StudioTheme.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isSpecial ? color : StudioTheme.text,
                      ),
                    ),
                    if (state != null && state.clip.isNotEmpty)
                      Text(
                        '▶ ${state.clip}',
                        overflow: TextOverflow.ellipsis,
                        style: StudioTheme.label,
                      ),
                  ],
                ),
              ),
              StudioIconButton(
                icon: Icons.arrow_right_alt,
                tooltip: node == entryNode
                    ? 'Choose the entry state'
                    : 'Start a transition from here',
                size: 22,
                active: linking,
                onTap: () => setState(() => _linkFrom = linking ? null : node),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The transition whose arrow passes within a few pixels of [at].
  int? _transitionAt(Offset at, AnimatorGraph g) {
    for (var i = g.transitions.length - 1; i >= 0; i--) {
      final t = g.transitions[i];
      if (g.stateNamed(t.to) == null) continue;
      if (!t.isFromAny && g.stateNamed(t.from) == null) continue;
      final line = arrowBetween(rectOf(t.from, g), rectOf(t.to, g));
      if (_distanceToSegment(at, line.$1, line.$2) <= 7) return i;
    }
    return null;
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(
      0.0,
      1.0,
    );
    return (p - (a + ab * t)).distance;
  }
}

/// The line an arrow follows between two nodes: edge to edge, nudged to one
/// side so A→B and B→A do not lie on top of each other.
(Offset, Offset) arrowBetween(Rect from, Rect to) {
  final d = to.center - from.center;
  final length = d.distance;
  if (length < 1) return (from.center, to.center);
  final unit = d / length;
  final side = Offset(-unit.dy, unit.dx) * 7;
  Offset edge(Rect r, Offset towards) {
    final sx = towards.dx == 0
        ? double.infinity
        : (r.width / 2) / towards.dx.abs();
    final sy = towards.dy == 0
        ? double.infinity
        : (r.height / 2) / towards.dy.abs();
    return r.center + towards * math.min(sx, sy);
  }

  return (edge(from, unit) + side, edge(to, -unit) + side);
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter({
    required this.graph,
    required this.pan,
    required this.rectOf,
    required this.selected,
  });

  final AnimatorGraph graph;
  final Offset pan;
  final Rect Function(String node) rectOf;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    // A dotted ground, so panning can be felt.
    final dot = Paint()..color = const Color(0x22FFFFFF);
    for (var x = pan.dx % 24; x < size.width; x += 24) {
      for (var y = pan.dy % 24; y < size.height; y += 24) {
        canvas.drawCircle(Offset(x, y), 1, dot);
      }
    }
    canvas.translate(pan.dx, pan.dy);

    final entry = graph.entryState;
    if (entry != null) {
      _arrow(
        canvas,
        rectOf(AnimatorGraphEditorState.entryNode),
        rectOf(entry.name),
        const Color(0xFF7DE6B1),
        2,
      );
    }
    for (var i = 0; i < graph.transitions.length; i++) {
      final t = graph.transitions[i];
      if (graph.stateNamed(t.to) == null) continue;
      if (!t.isFromAny && graph.stateNamed(t.from) == null) continue;
      final isSelected = i == selected;
      _arrow(
        canvas,
        rectOf(t.from),
        rectOf(t.to),
        isSelected
            ? StudioTheme.accent
            : t.isFromAny
            ? const Color(0xFF6FA8F5)
            : StudioTheme.textMuted,
        isSelected ? 2.5 : 1.5,
        // A badge for "waits for the clip" and for how many conditions.
        label: [
          if (t.hasExitTime) '⏱',
          if (t.conditions.isNotEmpty) '${t.conditions.length}',
        ].join(' '),
      );
    }
  }

  void _arrow(
    Canvas canvas,
    Rect from,
    Rect to,
    Color color,
    double width, {
    String label = '',
  }) {
    final (a, b) = arrowBetween(from, to);
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    canvas.drawLine(a, b, paint);
    final d = b - a;
    if (d.distance < 1) return;
    final unit = d / d.distance;
    final normal = Offset(-unit.dy, unit.dx);
    final head = Path()
      ..moveTo(b.dx, b.dy)
      ..lineTo(
        (b - unit * 9 + normal * 4.5).dx,
        (b - unit * 9 + normal * 4.5).dy,
      )
      ..lineTo(
        (b - unit * 9 - normal * 4.5).dx,
        (b - unit * 9 - normal * 4.5).dy,
      )
      ..close();
    canvas.drawPath(head, Paint()..color = color);
    if (label.isEmpty) return;
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final mid = (a + b) / 2 + normal * 9;
    text.paint(canvas, mid - Offset(text.width / 2, text.height / 2));
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.graph != graph || old.pan != pan || old.selected != selected;
}

// ── Side panels ──────────────────────────────────────────────────────────────

class _TextBox extends StatelessWidget {
  const _TextBox({
    super.key,
    required this.value,
    required this.onSubmitted,
    this.hint,
  });

  final String value;
  final String? hint;
  final ValueChanged<String> onSubmitted;

  /// Kept on Enter or on leaving the field — Tab, a click elsewhere — as
  /// every typed field in the editor is; Esc puts back what was there.
  @override
  Widget build(BuildContext context) => CommitTextField(
    value: value,
    onCommit: onSubmitted,
    style: StudioTheme.body,
    decoration: InputDecoration(
      isDense: true,
      filled: true,
      fillColor: StudioTheme.field,
      hintText: hint,
      hintStyle: StudioTheme.label,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      border: OutlineInputBorder(
        borderSide: BorderSide(color: StudioTheme.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: StudioTheme.border),
      ),
    ),
  );
}

class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.value,
    required this.options,
    required this.label,
    required this.onChanged,
  });

  final T value;
  final List<T> options;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: '',
    color: StudioTheme.panelRaised,
    padding: EdgeInsets.zero,
    onSelected: onChanged,
    itemBuilder: (context) => [
      for (final o in options)
        PopupMenuItem(
          value: o,
          height: 28,
          child: Text(label(o), style: StudioTheme.body),
        ),
    ],
    child: Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: StudioTheme.field,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: StudioTheme.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label(value),
              overflow: TextOverflow.ellipsis,
              style: StudioTheme.body,
            ),
          ),
          Icon(Icons.arrow_drop_down, size: 14, color: StudioTheme.textMuted),
        ],
      ),
    ),
  );
}

Widget _labelled(String label, Widget child) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Row(
    children: [
      SizedBox(width: 76, child: Text(label, style: StudioTheme.label)),
      Expanded(child: child),
    ],
  ),
);

class _ParametersPanel extends StatelessWidget {
  const _ParametersPanel({required this.session});

  final AnimatorGraphSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final bindings = ['', ...s.bindings.ids];
    return ColoredBox(
      color: StudioTheme.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            'Parameters',
            actions: [
              StudioIconButton(
                icon: Icons.add,
                tooltip: 'New parameter',
                size: 22,
                onTap: s.addParameter,
              ),
            ],
          ),
          Expanded(
            child: s.g.parameters.isEmpty
                ? Padding(
                    padding: EdgeInsets.all(10),
                    child: Text(
                      'Parameters are what transitions test: a speed, '
                      'whether the character is on the ground, a "jumped" '
                      'trigger. Bind one to the entity and it fills itself '
                      'in; otherwise the game sets it.',
                      style: StudioTheme.label,
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(8),
                    children: [
                      for (final p in s.g.parameters)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: StudioTheme.panelRaised,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      height: 26,
                                      child: _TextBox(
                                        key: ValueKey('p:${p.name}'),
                                        value: p.name,
                                        onSubmitted: (v) => s.updateParameter(
                                          p.name,
                                          p.copyWith(name: v.trim()),
                                        ),
                                      ),
                                    ),
                                  ),
                                  StudioIconButton(
                                    icon: Icons.close,
                                    tooltip: 'Remove (and its conditions)',
                                    size: 22,
                                    onTap: () => s.removeParameter(p.name),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  Expanded(
                                    child: _Choice<AnimatorParameterType>(
                                      value: p.type,
                                      options: AnimatorParameterType.values,
                                      label: (t) => t.name,
                                      onChanged: (t) => s.updateParameter(
                                        p.name,
                                        AnimatorParameter(
                                          name: p.name,
                                          type: t,
                                          binding: p.binding,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: _Choice<String>(
                                      value: p.binding ?? '',
                                      options: bindings,
                                      label: (b) => b.isEmpty
                                          ? 'set by the game'
                                          : '⇠ $b',
                                      onChanged: (b) => s.updateParameter(
                                        p.name,
                                        b.isEmpty
                                            ? p.copyWith(clearBinding: true)
                                            : p.copyWith(binding: b),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Inspector extends StatelessWidget {
  const _Inspector({super.key, required this.session, required this.clips});

  final AnimatorGraphSession session;
  final List<String> clips;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final sel = s.selection.value;
    final state = sel?.state == null ? null : s.g.stateNamed(sel!.state!);
    final index = sel?.transition;
    final transition = index != null && index < s.g.transitions.length
        ? s.g.transitions[index]
        : null;
    return ColoredBox(
      color: StudioTheme.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            state != null
                ? 'State'
                : transition != null
                ? 'Transition'
                : 'Inspector',
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: state != null
                  ? _state(s, state)
                  : transition != null
                  ? _transition(s, index!, transition)
                  : Text(
                      'Select a state or an arrow.\n\nA state plays one clip. '
                      'An arrow is a way out of it, taken when all its '
                      'conditions hold. Any State leads somewhere from '
                      'wherever the machine is — a hit, a death.',
                      style: StudioTheme.label,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _state(AnimatorGraphSession s, AnimatorState state) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _labelled(
        'Name',
        SizedBox(
          height: 26,
          child: _TextBox(
            value: state.name,
            onSubmitted: (v) =>
                s.updateState(state.name, state.copyWith(name: v.trim())),
          ),
        ),
      ),
      _labelled(
        'Clip',
        _Choice<String>(
          value: state.clip,
          options: ['', ...clips],
          label: (c) => c.isEmpty ? 'same as the name' : c,
          onChanged: (c) => s.updateState(state.name, state.copyWith(clip: c)),
        ),
      ),
      _labelled(
        'Speed',
        SizedBox(
          height: 26,
          child: _TextBox(
            value: '${state.speed}',
            onSubmitted: (v) {
              final speed = double.tryParse(v.trim());
              if (speed != null && speed >= 0) {
                s.updateState(state.name, state.copyWith(speed: speed));
              }
            },
          ),
        ),
      ),
      _labelled(
        'Loops',
        _Choice<bool?>(
          value: state.loop,
          options: const [null, true, false],
          label: (v) => v == null
              ? "the clip's own"
              : v
              ? 'yes'
              : 'no — play once',
          onChanged: (v) => s.updateState(
            state.name,
            v == null
                ? state.copyWith(clearLoop: true)
                : state.copyWith(loop: v),
          ),
        ),
      ),
      _labelled(
        'Timeline',
        SizedBox(
          height: 26,
          child: Tooltip(
            message:
                'A .timeline.json the Timeline Player of the entity plays on '
                'entering this state. Exit time then waits for the timeline.',
            waitDuration: const Duration(milliseconds: 600),
            child: _TextBox(
              value: state.timeline,
              onSubmitted: (v) =>
                  s.updateState(state.name, state.copyWith(timeline: v.trim())),
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      _blendTree(s, state),
      const SizedBox(height: 8),
      // A Wrap, not a Row: with a large text scale the two do not fit side
      // by side, and wrapping is better than clipping.
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (s.g.entryState?.name != state.name)
            TextButton(
              onPressed: () => s.setEntry(state.name),
              child: const Text('Make entry'),
            )
          else
            Text('The entry state', style: StudioTheme.label),
          TextButton(
            onPressed: () => s.removeState(state.name),
            child: Text('Delete', style: TextStyle(color: StudioTheme.danger)),
          ),
        ],
      ),
    ],
  );

  /// A state's blend tree: none (a button to add one), or its parameters
  /// and motions.
  Widget _blendTree(AnimatorGraphSession s, AnimatorState state) {
    final tree = state.blend;
    if (tree == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          message:
              'Play several clips weighted by a parameter: walk to run by '
              'speed. A sprite plays the heaviest; a 3-D model blends them.',
          waitDuration: const Duration(milliseconds: 600),
          child: TextButton(onPressed: () => s.addBlendTree(state), child: const Text('Blend by a parameter')),
        ),
      );
    }
    final numbers = [
      for (final p in s.g.parameters)
        if (p.type == AnimatorParameterType.float || p.type == AnimatorParameterType.int) p.name,
    ];
    void update(AnimatorBlendTree next) => s.updateState(state.name, state.copyWith(blend: next));
    Widget number(String value, void Function(double) onValue) => SizedBox(
      height: 26,
      width: 54,
      child: _TextBox(
        value: value,
        onSubmitted: (v) {
          final x = double.tryParse(v.trim());
          if (x != null) onValue(x);
        },
      ),
    );
    final twoD = tree.type == AnimatorBlendType.twoD;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('BLEND TREE', style: StudioTheme.heading),
        _labelled(
          'Axes',
          _Choice<AnimatorBlendType>(
            value: tree.type,
            options: AnimatorBlendType.values,
            label: (t) => t == AnimatorBlendType.oneD ? 'one parameter' : 'two parameters',
            onChanged: (t) => update(tree.copyWith(type: t, parameterY: tree.parameterY.isEmpty ? tree.parameter : null)),
          ),
        ),
        _labelled(
          twoD ? 'Across' : 'By',
          _Choice<String>(
            value: tree.parameter,
            options: {...numbers, tree.parameter}.toList(),
            label: (p) => p,
            onChanged: (p) => update(tree.copyWith(parameter: p)),
          ),
        ),
        if (twoD)
          _labelled(
            'Up',
            _Choice<String>(
              value: tree.parameterY,
              options: {...numbers, tree.parameterY}.toList(),
              label: (p) => p,
              onChanged: (p) => update(tree.copyWith(parameterY: p)),
            ),
          ),
        for (var i = 0; i < tree.motions.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Expanded(
                  child: _Choice<String>(
                    value: tree.motions[i].clip,
                    options: {...clips, tree.motions[i].clip}.toList(),
                    label: (c) => c.isEmpty ? '(no clip)' : c,
                    onChanged: (c) => update(
                      tree.copyWith(
                        motions: [
                          for (var k = 0; k < tree.motions.length; k++)
                            k == i ? _motion(tree.motions[k], clip: c) : tree.motions[k],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (!twoD)
                  number('${tree.motions[i].threshold}', (x) => update(_withMotion(tree, i, threshold: x)))
                else ...[
                  number('${tree.motions[i].x}', (x) => update(_withMotion(tree, i, x: x))),
                  const SizedBox(width: 2),
                  number('${tree.motions[i].y}', (y) => update(_withMotion(tree, i, y: y))),
                ],
                StudioIconButton(
                  icon: Icons.close,
                  tooltip: 'Remove this motion',
                  size: 22,
                  onTap: () => update(
                    tree.copyWith(motions: [
                      for (var k = 0; k < tree.motions.length; k++)
                        if (k != i) tree.motions[k],
                    ]),
                  ),
                ),
              ],
            ),
          ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () => update(
                tree.copyWith(motions: [...tree.motions, AnimatorBlendMotion(clip: state.clipName)]),
              ),
              child: const Text('Add motion'),
            ),
            TextButton(
              onPressed: () => s.updateState(state.name, state.copyWith(clearBlend: true)),
              child: Text('Remove blend', style: TextStyle(color: StudioTheme.danger)),
            ),
          ],
        ),
      ],
    );
  }

  static AnimatorBlendMotion _motion(AnimatorBlendMotion m, {String? clip, double? threshold, double? x, double? y}) =>
      AnimatorBlendMotion(
        clip: clip ?? m.clip,
        threshold: threshold ?? m.threshold,
        x: x ?? m.x,
        y: y ?? m.y,
        speed: m.speed,
      );

  static AnimatorBlendTree _withMotion(AnimatorBlendTree tree, int i, {double? threshold, double? x, double? y}) =>
      tree.copyWith(
        motions: [
          for (var k = 0; k < tree.motions.length; k++)
            k == i ? _motion(tree.motions[k], threshold: threshold, x: x, y: y) : tree.motions[k],
        ],
      );

  Widget _transition(AnimatorGraphSession s, int index, AnimatorTransition t) {
    final params = s.g.parameters;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${t.isFromAny ? 'Any State' : t.from}  →  ${t.to}',
          style: StudioTheme.body.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                'CONDITIONS — all must hold',
                style: StudioTheme.heading,
              ),
            ),
            StudioIconButton(
              icon: Icons.add,
              tooltip: params.isEmpty
                  ? 'Add a parameter first'
                  : 'Add a condition',
              size: 22,
              onTap: params.isEmpty
                  ? null
                  : () => s.updateTransition(
                      index,
                      t.copyWith(
                        conditions: [
                          ...t.conditions,
                          s.defaultConditionFor(params.first),
                        ],
                      ),
                    ),
            ),
          ],
        ),
        for (var i = 0; i < t.conditions.length; i++)
          _condition(s, index, t, i),
        if (t.conditions.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('None.', style: StudioTheme.label),
          ),
        const SizedBox(height: 10),
        InkWell(
          onTap: () => s.updateTransition(
            index,
            t.copyWith(hasExitTime: !t.hasExitTime),
          ),
          child: Row(
            children: [
              Icon(
                t.hasExitTime ? Icons.check_box : Icons.check_box_outline_blank,
                size: 14,
                color: t.hasExitTime
                    ? StudioTheme.accent
                    : StudioTheme.textMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Wait for the clip (exit time)',
                  style: StudioTheme.body,
                ),
              ),
            ],
          ),
        ),
        if (t.hasExitTime)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _labelled(
              'How far, 0–1',
              SizedBox(
                height: 26,
                child: _TextBox(
                  value: '${t.exitTime}',
                  onSubmitted: (v) {
                    final x = double.tryParse(v.trim());
                    if (x != null) {
                      s.updateTransition(
                        index,
                        t.copyWith(exitTime: x.clamp(0.0, 1.0)),
                      );
                    }
                  },
                ),
              ),
            ),
          ),
        const SizedBox(height: 6),
        _labelled(
          'Blend (s)',
          SizedBox(
            height: 26,
            child: Tooltip(
              message:
                  'Seconds the old state fades into the new one. A 3-D model '
                  'crossfades; a sprite always cuts.',
              waitDuration: const Duration(milliseconds: 600),
              child: _TextBox(
                value: '${t.duration}',
                onSubmitted: (v) {
                  final d = double.tryParse(v.trim());
                  if (d != null && d >= 0) {
                    s.updateTransition(index, t.copyWith(duration: d));
                  }
                },
              ),
            ),
          ),
        ),
        _labelled(
          'Priority',
          SizedBox(
            height: 26,
            child: _TextBox(
              value: '${t.priority}',
              onSubmitted: (v) {
                final p = int.tryParse(v.trim());
                if (p != null) {
                  s.updateTransition(index, t.copyWith(priority: p));
                }
              },
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => s.removeTransition(index),
            child: Text('Delete', style: TextStyle(color: StudioTheme.danger)),
          ),
        ),
      ],
    );
  }

  Widget _condition(
    AnimatorGraphSession s,
    int index,
    AnimatorTransition t,
    int i,
  ) {
    final c = t.conditions[i];
    final type = s.g.parameterNamed(c.parameter)?.type;
    void replace(AnimatorCondition? next) => s.updateTransition(
      index,
      t.copyWith(
        conditions: [
          for (var k = 0; k < t.conditions.length; k++)
            if (k != i) t.conditions[k] else ?next,
        ],
      ),
    );
    final isNumber =
        type == AnimatorParameterType.float ||
        type == AnimatorParameterType.int;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: _Choice<String>(
              value: c.parameter,
              options: [for (final p in s.g.parameters) p.name],
              label: (n) => n,
              onChanged: (n) =>
                  replace(s.defaultConditionFor(s.g.parameterNamed(n)!)),
            ),
          ),
          if (isNumber) ...[
            const SizedBox(width: 4),
            SizedBox(
              width: 48,
              child: _Choice<AnimatorOp>(
                value: c.op,
                options: AnimatorOp.values,
                label: (o) => o.symbol,
                onChanged: (o) => replace(
                  AnimatorCondition(
                    parameter: c.parameter,
                    op: o,
                    value: c.value,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              flex: 3,
              child: SizedBox(
                height: 26,
                child: _TextBox(
                  key: ValueKey('c:$index:$i:${c.value}'),
                  value: '${c.value}',
                  onSubmitted: (v) {
                    final n = num.tryParse(v.trim());
                    if (n != null) {
                      replace(
                        AnimatorCondition(
                          parameter: c.parameter,
                          op: c.op,
                          value: n,
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
          ] else if (type == AnimatorParameterType.bool) ...[
            const SizedBox(width: 4),
            Expanded(
              flex: 3,
              child: _Choice<bool>(
                value: c.value == true,
                options: const [true, false],
                label: (v) => v ? 'is true' : 'is false',
                onChanged: (v) => replace(
                  AnimatorCondition(parameter: c.parameter, value: v),
                ),
              ),
            ),
          ] else
            Expanded(
              flex: 3,
              child: Padding(
                padding: EdgeInsets.only(left: 6),
                child: Text('is set', style: StudioTheme.label),
              ),
            ),
          StudioIconButton(
            icon: Icons.close,
            tooltip: 'Remove',
            size: 22,
            onTap: () => replace(null),
          ),
        ],
      ),
    );
  }
}
