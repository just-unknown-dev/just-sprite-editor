import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_game_engine/just_game_engine.dart';
import 'package:just_editor_core/just_editor_core.dart'
    show PackageAssetPaths;

import '../studio_files.dart';

/// What is selected in the graph: a state, a transition, or nothing.
class GraphSelection {
  const GraphSelection.state(String name) : state = name, transition = null;
  const GraphSelection.transition(int index) : state = null, transition = index;

  final String? state;
  final int? transition;

  @override
  bool operator ==(Object other) =>
      other is GraphSelection &&
      other.state == state &&
      other.transition == transition;

  @override
  int get hashCode => Object.hash(state, transition);
}

/// One open animator graph. The graph itself is immutable, so an edit is a
/// new graph and undo is the list of old ones.
class AnimatorGraphSession {
  AnimatorGraphSession(
    AnimatorGraph graph, {
    this.path,
    String? root,
    AnimatorBindings? bindings,
  }) : root = (root ?? Directory.current.path).replaceAll('\\', '/'),
       bindings = bindings ?? AnimatorBindings.builtIn,
       graph = Signal(graph, debugLabel: 'animatorGraph') {
    _saved = graph;
  }

  final String root;

  /// What a parameter can be bound to: the edited engine's bindings (the
  /// engine's own when none were given).
  final AnimatorBindings bindings;

  /// Project-relative path of the `.animator.json`; null until first saved.
  String? path;

  final Signal<AnimatorGraph> graph;
  final Signal<GraphSelection?> selection = Signal(
    null,
    debugLabel: 'graphSelection',
  );
  final Signal<String?> message = Signal(null, debugLabel: 'graphMessage');

  final List<AnimatorGraph> _undo = [];
  final List<AnimatorGraph> _redo = [];
  late AnimatorGraph _saved;

  static const String extension = 'animator.json';

  AnimatorGraph get g => graph.value;
  bool get isDirty => !identical(_saved, graph.value);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// The file's name, or what a graph not yet saved is called.
  String get fileName => path?.split('/').last ?? 'Untitled.$extension';

  /// [fileName], with a dot while there is work not saved.
  String get title => isDirty ? '$fileName •' : fileName;

  void say(String text) => message.forceSet(text);

  /// Replaces the graph, as one undo step.
  void apply(AnimatorGraph next) {
    _undo.add(graph.value);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    graph.value = next;
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(graph.value);
    graph.value = _undo.removeLast();
    _dropStaleSelection();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(graph.value);
    graph.value = _redo.removeLast();
    _dropStaleSelection();
  }

  void _dropStaleSelection() {
    final s = selection.value;
    if (s == null) return;
    final gone = s.state != null
        ? g.stateNamed(s.state!) == null
        : s.transition! >= g.transitions.length;
    if (gone) selection.value = null;
  }

  // ── States ───────────────────────────────────────────────────────────────

  String _uniqueState(String base) {
    var name = base, n = 2;
    while (g.stateNamed(name) != null) {
      name = '$base$n';
      n++;
    }
    return name;
  }

  /// Adds a state at ([x], [y]). Named after [clip] when given, so the state
  /// plays the clip it is named for without saying so twice.
  String addState(double x, double y, {String? clip}) {
    final name = _uniqueState(clip == null || clip.isEmpty ? 'state' : clip);
    apply(
      g.copyWith(
        states: [
          ...g.states,
          AnimatorState(
            name: name,
            clip: clip != null && clip != name ? clip : '',
            x: x,
            y: y,
          ),
        ],
        entry: g.states.isEmpty ? name : g.entry,
      ),
    );
    selection.value = GraphSelection.state(name);
    return name;
  }

  /// One state per clip not already played by some state, laid out in a row.
  int addStatesForClips(List<String> clips) {
    final have = {for (final s in g.states) s.clipName};
    final missing = [
      for (final c in clips)
        if (!have.contains(c)) c,
    ];
    if (missing.isEmpty) return 0;
    var next = g;
    var x = 260.0 + g.states.length * 40;
    for (final clip in missing) {
      // Named for its clip, unless a state already has that name — one
      // that plays another clip: then a name of its own, and the clip said.
      final taken = {for (final s in next.states) s.name};
      var name = clip, n = 2;
      while (taken.contains(name)) {
        name = '$clip$n';
        n++;
      }
      next = next.copyWith(
        states: [
          ...next.states,
          AnimatorState(
            name: name,
            clip: name == clip ? '' : clip,
            x: x,
            y: 80.0 + next.states.length % 3 * 90,
          ),
        ],
        entry: next.states.isEmpty && next.entry.isEmpty ? name : next.entry,
      );
      x += 170;
    }
    apply(next);
    return missing.length;
  }

  void updateState(String name, AnimatorState next) {
    final renamed = next.name != name;
    if (renamed && (next.name.isEmpty || g.stateNamed(next.name) != null)) {
      return say('A state needs a name of its own.');
    }
    apply(
      g.copyWith(
        states: [for (final s in g.states) s.name == name ? next : s],
        // A rename follows through everything that named the state.
        transitions: !renamed
            ? null
            : [
                for (final t in g.transitions)
                  t.copyWith(
                    from: t.from == name ? next.name : t.from,
                    to: t.to == name ? next.name : t.to,
                  ),
              ],
        entry: renamed && g.entry == name ? next.name : null,
      ),
    );
    if (renamed) selection.value = GraphSelection.state(next.name);
  }

  /// Moves a node without an undo step per pixel: [commit] once, at the end
  /// of the drag.
  void moveState(String name, double x, double y, {required bool commit}) {
    final next = g.copyWith(
      states: [
        for (final s in g.states) s.name == name ? s.copyWith(x: x, y: y) : s,
      ],
    );
    if (commit) {
      // One step back is where the node was before the drag began, not
      // where it was a pixel ago.
      _undo.add(_dragBase ?? graph.value);
      if (_undo.length > 200) _undo.removeAt(0);
      _dragBase = null;
      _redo.clear();
      graph.value = next;
    } else {
      _dragBase ??= graph.value;
      graph.value = next;
    }
  }

  /// Ends a drag of [name] that stopped without a release — the pointer
  /// lost: where the node got to stays, as the one step the drag is.
  void endMove(String name) {
    if (_dragBase == null) return;
    final now = g.stateNamed(name);
    if (now == null) {
      _dragBase = null;
      return;
    }
    moveState(name, now.x, now.y, commit: true);
  }

  AnimatorGraph? _dragBase;

  void removeState(String name) {
    apply(
      g.copyWith(
        states: [
          for (final s in g.states)
            if (s.name != name) s,
        ],
        transitions: [
          for (final t in g.transitions)
            if (t.from != name && t.to != name) t,
        ],
        entry: g.entry == name ? '' : null,
      ),
    );
    selection.value = null;
  }

  void setEntry(String name) => apply(g.copyWith(entry: name));

  // ── Transitions ──────────────────────────────────────────────────────────

  /// Adds [from] → [to] and selects it. A transition from Any State to a
  /// state, or between two different states; one that already exists is
  /// selected instead.
  void addTransition(String from, String to) {
    if (from == to) return say('A state cannot lead to itself.');
    final existing = g.transitions.indexWhere(
      (t) => t.from == from && t.to == to,
    );
    if (existing >= 0) {
      selection.value = GraphSelection.transition(existing);
      return;
    }
    apply(
      g.copyWith(
        transitions: [
          ...g.transitions,
          // Starts as "when the clip ends": harmless, and visibly a
          // transition, until the author gives it conditions.
          AnimatorTransition(from: from, to: to, hasExitTime: true),
        ],
      ),
    );
    selection.value = GraphSelection.transition(g.transitions.length - 1);
  }

  void updateTransition(int index, AnimatorTransition next) => apply(
    g.copyWith(
      transitions: [
        for (var i = 0; i < g.transitions.length; i++)
          i == index ? next : g.transitions[i],
      ],
    ),
  );

  void removeTransition(int index) {
    apply(
      g.copyWith(
        transitions: [
          for (var i = 0; i < g.transitions.length; i++)
            if (i != index) g.transitions[i],
        ],
      ),
    );
    selection.value = null;
  }

  // ── Parameters ───────────────────────────────────────────────────────────

  void addParameter({
    String name = 'param',
    AnimatorParameterType type = AnimatorParameterType.float,
    String? binding,
  }) {
    var unique = name, n = 2;
    while (g.parameterNamed(unique) != null) {
      unique = '$name$n';
      n++;
    }
    apply(
      g.copyWith(
        parameters: [
          ...g.parameters,
          AnimatorParameter(name: unique, type: type, binding: binding),
        ],
      ),
    );
  }

  void updateParameter(String name, AnimatorParameter next) {
    final renamed = next.name != name;
    if (renamed && (next.name.isEmpty || g.parameterNamed(next.name) != null)) {
      return say('A parameter needs a name of its own.');
    }
    apply(
      g.copyWith(
        parameters: [for (final p in g.parameters) p.name == name ? next : p],
        // Blend trees follow the rename too.
        states: !renamed
            ? null
            : [
                for (final st in g.states)
                  st.blend == null
                      ? st
                      : st.copyWith(
                          blend: st.blend!.copyWith(
                            parameter: st.blend!.parameter == name ? next.name : null,
                            parameterY: st.blend!.parameterY == name ? next.name : null,
                          ),
                        ),
              ],
        transitions: !renamed
            ? null
            : [
                for (final t in g.transitions)
                  t.copyWith(
                    conditions: [
                      for (final c in t.conditions)
                        c.parameter == name
                            ? AnimatorCondition(
                                parameter: next.name,
                                op: c.op,
                                value: c.value,
                              )
                            : c,
                    ],
                  ),
              ],
      ),
    );
  }

  /// Removes a parameter and every condition that tested it. A blend tree
  /// that blended by it keeps its motions but no longer names it: the
  /// graph's problems say so, until another parameter is picked.
  void removeParameter(String name) => apply(
    g.copyWith(
      parameters: [
        for (final p in g.parameters)
          if (p.name != name) p,
      ],
      states: [
        for (final st in g.states)
          st.blend == null ||
                  (st.blend!.parameter != name && st.blend!.parameterY != name)
              ? st
              : st.copyWith(
                  blend: st.blend!.copyWith(
                    parameter: st.blend!.parameter == name ? '' : null,
                    parameterY: st.blend!.parameterY == name ? '' : null,
                  ),
                ),
      ],
      transitions: [
        for (final t in g.transitions)
          t.copyWith(
            conditions: [
              for (final c in t.conditions)
                if (c.parameter != name) c,
            ],
          ),
      ],
    ),
  );

  /// [state] blending by a number parameter: a 1-D tree with its current
  /// clip as the one motion, to add to. Says so when there is no number
  /// parameter to blend by.
  void addBlendTree(AnimatorState state) {
    final numbers = [
      for (final p in g.parameters)
        if (p.type == AnimatorParameterType.float || p.type == AnimatorParameterType.int) p.name,
    ];
    if (numbers.isEmpty) return say('Add a number parameter to blend by first.');
    updateState(
      state.name,
      state.copyWith(
        blend: AnimatorBlendTree(
          parameter: numbers.first,
          motions: [AnimatorBlendMotion(clip: state.clipName)],
        ),
      ),
    );
  }

  /// A condition that makes sense for [parameter]'s type, to start from.
  AnimatorCondition defaultConditionFor(AnimatorParameter parameter) =>
      switch (parameter.type) {
        AnimatorParameterType.float ||
        AnimatorParameterType.int => AnimatorCondition(
          parameter: parameter.name,
          op: AnimatorOp.greater,
          value: 0,
        ),
        _ => AnimatorCondition(parameter: parameter.name),
      };

  // ── The atlas: where clip names come from ────────────────────────────────

  /// [readClipNames], kept: the file is read again only when the clip
  /// source changes — its path, or the file's time or size, looked at no
  /// more than once a second. What a view asks on every build.
  List<String> clipNames() {
    final atlas = g.atlasPath.trim();
    final now = DateTime.now();
    final checked = _clipsCheckedAt;
    if (atlas == _clipsOf &&
        checked != null &&
        now.difference(checked) < const Duration(seconds: 1)) {
      return _clips;
    }
    _clipsCheckedAt = now;
    final stamp = _stampOf(atlas);
    if (atlas == _clipsOf && stamp == _clipsStamp) return _clips;
    _clipsOf = atlas;
    _clipsStamp = stamp;
    return _clips = readClipNames();
  }

  List<String> _clips = const [];
  String? _clipsOf;
  String? _clipsStamp;
  DateTime? _clipsCheckedAt;

  String? _stampOf(String atlas) {
    if (atlas.isEmpty) return null;
    try {
      final stat = PackageAssetPaths.of(root).file(atlas).statSync();
      return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
    } on FileSystemException {
      return null;
    }
  }

  /// The clips of the graph's atlas, read from its JSON; empty when there
  /// is none or it cannot be read. Reads the file every time: [clipNames]
  /// is the one to ask often.
  List<String> readClipNames() {
    final atlas = g.atlasPath.trim();
    if (atlas.isEmpty) return const [];
    // A 3-D model's animations, for a graph that plays on its skeleton.
    final lower = atlas.toLowerCase();
    if (lower.endsWith('.glb') || lower.endsWith('.gltf')) {
      try {
        return modelClipNames(
          _modelJson(PackageAssetPaths.of(root).file(atlas)),
        );
      } catch (_) {
        return const [];
      }
    }
    try {
      final json = jsonDecode(
        PackageAssetPaths.of(root).file(atlas).readAsStringSync(),
      );
      final meta = json is Map ? json['meta'] : null;
      final tags = meta is Map ? meta['frameTags'] : null;
      final legacy = json is Map ? json['clips'] : null;
      return [
        if (tags is List)
          for (final t in tags)
            if (t is Map && t['name'] is String) t['name'] as String,
        if (legacy is Map) ...legacy.keys.cast<String>(),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// What of a model [file] [modelClipNames] needs: a `.gltf` whole, but of
  /// a `.glb` only its header and JSON chunk — not the meshes and textures
  /// after them, which can be most of the file.
  static Uint8List _modelJson(File file) {
    final raf = file.openSync();
    try {
      final head = raf.readSync(20);
      final isGlb =
          head.length >= 20 &&
          head[0] == 0x67 &&
          head[1] == 0x6C &&
          head[2] == 0x54 &&
          head[3] == 0x46;
      if (!isGlb) {
        raf.setPositionSync(0);
        return raf.readSync(raf.lengthSync());
      }
      final length = ByteData.sublistView(head).getUint32(12, Endian.little);
      return (BytesBuilder(copy: false)
            ..add(head)
            ..add(raf.readSync(length)))
          .toBytes();
    } finally {
      raf.closeSync();
    }
  }

  /// The animation names of a glTF model, `.glb` or `.gltf` [bytes], as a
  /// game names its clips: an unnamed one `animation <index>`.
  static List<String> modelClipNames(Uint8List bytes) {
    String text;
    // A .glb: 'glTF', version, length, then the JSON chunk.
    if (bytes.length >= 20 &&
        bytes[0] == 0x67 &&
        bytes[1] == 0x6C &&
        bytes[2] == 0x54 &&
        bytes[3] == 0x46) {
      final view = ByteData.sublistView(bytes);
      final length = view.getUint32(12, Endian.little);
      text = utf8.decode(Uint8List.sublistView(bytes, 20, 20 + length));
    } else {
      text = utf8.decode(bytes);
    }
    final json = jsonDecode(text);
    final animations = json is Map ? json['animations'] : null;
    if (animations is! List) return const [];
    return [
      for (var i = 0; i < animations.length; i++)
        switch (animations[i]) {
          {'name': final String name} when name.isNotEmpty => name,
          _ => 'animation $i',
        },
    ];
  }

  // ── Files ────────────────────────────────────────────────────────────────

  Future<String> save({String? to}) async {
    final target = to ?? path;
    if (target == null) {
      throw StateError('A new graph needs a path to save to.');
    }
    final file = PackageAssetPaths.of(root).file(target);
    await file.parent.create(recursive: true);
    // Whole or not at all: a failed save leaves the graph that was there.
    await writeAtomically(file, utf8.encode(g.encode()));
    path = target;
    _saved = graph.value;
    // Dirtiness is identity: tell listeners it changed without a new graph.
    graph.forceSet(graph.value);
    say('Saved ${target.split('/').last}');
    return target;
  }

  static Future<AnimatorGraphSession> open(
    String path, {
    String? root,
    AnimatorBindings? bindings,
  }) async {
    final base = (root ?? Directory.current.path).replaceAll('\\', '/');
    return AnimatorGraphSession(
      AnimatorGraph.parse(
        await PackageAssetPaths.of(base).file(path).readAsString(),
      ),
      path: path,
      root: base,
      bindings: bindings,
    );
  }

  void dispose() {
    graph.dispose();
    selection.dispose();
    message.dispose();
  }
}
