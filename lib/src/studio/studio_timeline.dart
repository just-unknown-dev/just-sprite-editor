import 'package:flutter/material.dart';
import 'package:just_editor_core/just_editor_core.dart'
    show CommitTextField;
import 'package:just_signals/just_signals.dart';

import '../document/sprite_document.dart';
import 'studio_panels.dart';
import 'studio_session.dart';
import 'studio_theme.dart';

/// The timeline: layers down, frames across, tags along the top, and the
/// transport that plays them.
class TimelinePanel extends StatelessWidget {
  const TimelinePanel({super.key, required this.session});

  final SpriteStudioSession session;

  static const double _cell = 24;
  static const double _names = 112;
  static const double _row = 22;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return SignalConsumer(
      signals: [
        s.structureRevision,
        s.frameIndex,
        s.layerIndex,
        s.isPlaying,
        s.playTag,
        s.onionSkin,
      ],
      builder: (context, _) {
        final doc = s.document;
        final frames = doc.frames.length;
        final onion = s.onionSkin.value;
        return Container(
          color: StudioTheme.panel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 30,
                color: StudioTheme.panelRaised,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    StudioIconButton(
                      icon: Icons.skip_previous,
                      tooltip: 'Previous frame  (,)',
                      size: 24,
                      onTap: () => s.stepFrame(-1),
                    ),
                    StudioIconButton(
                      icon: s.isPlaying.value ? Icons.pause : Icons.play_arrow,
                      tooltip: s.isPlaying.value
                          ? 'Pause  (Enter)'
                          : 'Play  (Enter)',
                      size: 24,
                      active: s.isPlaying.value,
                      onTap: frames > 1 ? s.togglePlay : null,
                    ),
                    StudioIconButton(
                      icon: Icons.skip_next,
                      tooltip: 'Next frame  (.)',
                      size: 24,
                      onTap: () => s.stepFrame(1),
                    ),
                    const SizedBox(width: 6),
                    _PlayRange(session: s),
                    const SizedBox(width: 12),
                    Text(
                      'Frame ${s.frameIndex.value + 1}/$frames',
                      style: StudioTheme.label,
                    ),
                    const SizedBox(width: 8),
                    _DurationField(
                      key: ValueKey('${s.frame.id}:${s.frame.durationMs}'),
                      ms: s.frame.durationMs,
                      onChanged: s.setFrameDuration,
                    ),
                    const SizedBox(width: 12),
                    StudioIconButton(
                      icon: Icons.layers_outlined,
                      tooltip: 'Onion skin: neighbouring frames, faintly',
                      size: 24,
                      active: onion.enabled,
                      onTap: () => s.onionSkin.value = onion.copyWith(
                        enabled: !onion.enabled,
                      ),
                    ),
                    if (onion.enabled)
                      Tooltip(
                        message: 'Frames shown either side',
                        child: InkWell(
                          onTap: () {
                            final n = onion.before % 3 + 1;
                            s.onionSkin.value = onion.copyWith(
                              before: n,
                              after: n,
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Text(
                              '±${onion.before}',
                              style: StudioTheme.label,
                            ),
                          ),
                        ),
                      ),
                    const Spacer(),
                    StudioIconButton(
                      icon: Icons.sell_outlined,
                      tooltip: 'Tag this frame as a clip',
                      size: 24,
                      onTap: () =>
                          s.addTag(s.frameIndex.value, s.frameIndex.value),
                    ),
                    StudioIconButton(
                      icon: Icons.content_copy,
                      tooltip: 'Duplicate frame  (Alt+N)',
                      size: 24,
                      onTap: s.addFrame,
                    ),
                    StudioIconButton(
                      icon: Icons.add_box_outlined,
                      tooltip: 'New empty frame',
                      size: 24,
                      onTap: () => s.addFrame(duplicate: false),
                    ),
                    StudioIconButton(
                      icon: Icons.delete_outline,
                      tooltip: 'Delete frame',
                      size: 24,
                      onTap: frames > 1 ? s.removeFrame : null,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: _names,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: _row * 2),
                            for (var l = doc.layers.length - 1; l >= 0; l--)
                              InkWell(
                                onTap: () => s.layerIndex.value = l,
                                child: Container(
                                  height: _row,
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.only(left: 8),
                                  color: l == s.layerIndex.value
                                      ? StudioTheme.selected
                                      : null,
                                  child: Text(
                                    doc.layers[l].name,
                                    overflow: TextOverflow.ellipsis,
                                    style: StudioTheme.label.copyWith(
                                      color: doc.layers[l].visible
                                          ? StudioTheme.text
                                          : StudioTheme.textMuted,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: frames * _cell + 8,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _TagRow(session: s),
                                Row(
                                  children: [
                                    for (var f = 0; f < frames; f++)
                                      _FrameNumber(session: s, index: f),
                                  ],
                                ),
                                for (var l = doc.layers.length - 1; l >= 0; l--)
                                  Row(
                                    children: [
                                      for (var f = 0; f < frames; f++)
                                        _CelCell(
                                          session: s,
                                          layer: l,
                                          frame: f,
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FrameNumber extends StatelessWidget {
  const _FrameNumber({required this.session, required this.index});

  final SpriteStudioSession session;
  final int index;

  @override
  Widget build(BuildContext context) {
    final active = index == session.frameIndex.value;
    return InkWell(
      onTap: () => session.goToFrame(index),
      child: Container(
        width: TimelinePanel._cell,
        height: TimelinePanel._row,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? StudioTheme.accent.withValues(alpha: 0.25) : null,
          border: Border(
            right: BorderSide(color: StudioTheme.border, width: 0.5),
          ),
        ),
        child: Text(
          '${index + 1}',
          style: StudioTheme.label.copyWith(
            color: active ? StudioTheme.text : StudioTheme.textMuted,
          ),
        ),
      ),
    );
  }
}

class _CelCell extends StatelessWidget {
  const _CelCell({
    required this.session,
    required this.layer,
    required this.frame,
  });

  final SpriteStudioSession session;
  final int layer;
  final int frame;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final doc = s.document;
    // Worked out once per change to the sprite, not on every rebuild.
    final hasArt = s.celHasArt(doc.layers[layer].id, doc.frames[frame].id);
    final active = layer == s.layerIndex.value && frame == s.frameIndex.value;
    final inRowOrColumn =
        layer == s.layerIndex.value || frame == s.frameIndex.value;
    return InkWell(
      onTap: () {
        s.layerIndex.value = layer;
        s.goToFrame(frame);
      },
      child: Container(
        width: TimelinePanel._cell,
        height: TimelinePanel._row,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? StudioTheme.selected
              : inRowOrColumn
              ? StudioTheme.panelRaised
              : null,
          border: Border.all(
            color: active ? StudioTheme.accent : StudioTheme.border,
            width: active ? 1 : 0.5,
          ),
        ),
        // A full dot where there is something drawn, a ring where there is
        // not: the shape of the animation at a glance.
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hasArt ? StudioTheme.text : null,
            border: hasArt
                ? null
                : Border.all(
                    color: StudioTheme.textMuted.withValues(alpha: 0.4),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Each tag as a bar over the frames it names. Click to edit.
class _TagRow extends StatelessWidget {
  const _TagRow({required this.session});

  final SpriteStudioSession session;

  @override
  Widget build(BuildContext context) {
    final doc = session.document;
    return SizedBox(
      height: TimelinePanel._row,
      child: Stack(
        children: [
          for (var i = 0; i < doc.tags.length; i++)
            Positioned(
              left: doc.tags[i].from * TimelinePanel._cell + 1,
              width:
                  (doc.tags[i].to - doc.tags[i].from + 1) *
                      TimelinePanel._cell -
                  2,
              top: 3,
              bottom: 3,
              child: Tooltip(
                message:
                    '${doc.tags[i].name} · ${doc.tags[i].direction.name}'
                    '${doc.tags[i].loop ? '' : ' · once'} — click to edit',
                waitDuration: const Duration(milliseconds: 400),
                child: InkWell(
                  onTap: () => editTag(context, session, i),
                  child: Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: Color(doc.tags[i].color).withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: Color(doc.tags[i].color)),
                    ),
                    child: Text(
                      doc.tags[i].name,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: StudioTheme.label.copyWith(
                        color: StudioTheme.text,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Which frames Play runs through: all of them, or one tag.
class _PlayRange extends StatelessWidget {
  const _PlayRange({required this.session});

  final SpriteStudioSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final tags = s.document.tags;
    final current = tags.any((t) => t.name == s.playTag.value)
        ? s.playTag.value
        : null;
    return PopupMenuButton<String>(
      tooltip: 'What Play plays',
      color: StudioTheme.panelRaised,
      padding: EdgeInsets.zero,
      onSelected: (v) => s.playTag.value = v.isEmpty ? null : v,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: '',
          height: 28,
          child: Text('All frames', style: StudioTheme.body),
        ),
        for (final t in tags)
          PopupMenuItem(
            value: t.name,
            height: 28,
            child: Text(t.name, style: StudioTheme.body),
          ),
      ],
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: StudioTheme.field,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: StudioTheme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(current ?? 'All frames', style: StudioTheme.label),
            Icon(Icons.arrow_drop_down, size: 14, color: StudioTheme.textMuted),
          ],
        ),
      ),
    );
  }
}

class _DurationField extends StatelessWidget {
  const _DurationField({super.key, required this.ms, required this.onChanged});

  final int ms;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'How long this frame shows, in milliseconds',
    waitDuration: const Duration(milliseconds: 400),
    child: SizedBox(
      width: 64,
      height: 22,
      // Kept on Enter or on leaving the field — Tab, a click elsewhere. What
      // is not a whole number above 0 puts back the one it had; so does Esc.
      child: CommitTextField(
        value: '$ms',
        accept: (text) => (int.tryParse(text.trim()) ?? 0) > 0,
        onCommit: (text) {
          final v = int.parse(text.trim());
          if (v != ms) onChanged(v);
        },
        textAlign: TextAlign.right,
        keyboardType: TextInputType.number,
        style: StudioTheme.body,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: StudioTheme.field,
          suffixText: ' ms',
          suffixStyle: StudioTheme.label,
          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          border: OutlineInputBorder(
            borderSide: BorderSide(color: StudioTheme.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: StudioTheme.border),
          ),
        ),
      ),
    ),
  );
}

//// The tag editor: name, range, direction, whether it loops, and its events.
Future<void> editTag(
  BuildContext context,
  SpriteStudioSession s,
  int index,
) async {
  final tag = s.document.tags[index];
  final result = await showDialog<_TagEdit>(
    context: context,
    builder: (context) => _TagDialog(tag: tag),
  );
  if (result == null) return;
  if (result.delete) {
    s.structural('Delete tag', (d) => d.tags.removeAt(index));
    return;
  }

  final last = s.document.frames.length - 1;
  final a = ((int.tryParse(result.from.trim()) ?? tag.from + 1) - 1).clamp(
    0,
    last,
  );
  final b = ((int.tryParse(result.to.trim()) ?? tag.to + 1) - 1).clamp(0, last);
  final parsed = <SpriteEvent>[
    for (final part in result.events.split(','))
      if (part.contains(':'))
        SpriteEvent(
          timeMs: int.tryParse(part.split(':').first.trim()) ?? 0,
          name: part.substring(part.indexOf(':') + 1).trim(),
        ),
  ]..sort((x, y) => x.timeMs.compareTo(y.timeMs));
  final wanted = result.name.trim().isEmpty ? tag.name : result.name.trim();
  final taken = s.document.tags.any((t) => t != tag && t.name == wanted);
  if (taken) s.say('Another tag is already called "$wanted".');
  s.structural('Edit tag', (d) {
    d.tags[index]
      ..name = taken ? tag.name : wanted
      ..from = a < b ? a : b
      ..to = a < b ? b : a
      ..direction = result.direction
      ..loop = result.loop
      ..events = parsed.where((e) => e.name.isNotEmpty).toList();
  });
}

/// What the tag dialog was left with: its fields as typed, or Delete.
class _TagEdit {
  const _TagEdit({
    this.delete = false,
    this.name = '',
    this.from = '',
    this.to = '',
    this.events = '',
    this.direction = TagDirection.forward,
    this.loop = true,
  });

  final bool delete;
  final String name;
  final String from;
  final String to;
  final String events;
  final TagDirection direction;
  final bool loop;
}

/// The tag dialog. It owns its fields' controllers, so they go when it
/// does — after its closing animation, not before.
class _TagDialog extends StatefulWidget {
  const _TagDialog({required this.tag});

  final SpriteTag tag;

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.tag.name,
  );
  late final TextEditingController _from = TextEditingController(
    text: '${widget.tag.from + 1}',
  );
  late final TextEditingController _to = TextEditingController(
    text: '${widget.tag.to + 1}',
  );
  late final TextEditingController _events = TextEditingController(
    text: [for (final e in widget.tag.events) '${e.timeMs}:${e.name}']
        .join(', '),
  );
  late TagDirection _direction = widget.tag.direction;
  late bool _loop = widget.tag.loop;

  @override
  void dispose() {
    _name.dispose();
    _from.dispose();
    _to.dispose();
    _events.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: StudioTheme.panel,
    title: Text('Tag', style: StudioTheme.body.copyWith(fontSize: 13)),
    content: SizedBox(
      width: 300,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field('Name — the clip the game plays', _name),
          Row(
            children: [
              Expanded(child: _field('From frame', _from)),
              const SizedBox(width: 8),
              Expanded(child: _field('To frame', _to)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final d in TagDirection.values)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ChoiceChip(
                    label: Text(d.name, style: StudioTheme.label),
                    selected: _direction == d,
                    onSelected: (_) => setState(() => _direction = d),
                  ),
                ),
            ],
          ),
          CheckboxListTile(
            value: _loop,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('Loops', style: StudioTheme.body),
            subtitle: Text(
              'Off for a jump or a hit: it plays once and holds.',
              style: StudioTheme.label,
            ),
            onChanged: (v) => setState(() => _loop = v ?? true),
          ),
          _field('Events — "120:step, 300:land" (ms:name)', _events),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () =>
            Navigator.of(context).pop(const _TagEdit(delete: true)),
        child: Text('Delete tag', style: TextStyle(color: StudioTheme.danger)),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(
          _TagEdit(
            name: _name.text,
            from: _from.text,
            to: _to.text,
            events: _events.text,
            direction: _direction,
            loop: _loop,
          ),
        ),
        child: const Text('OK'),
      ),
    ],
  );
}

Widget _field(String label, TextEditingController controller) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: TextField(
    controller: controller,
    style: StudioTheme.body,
    decoration: InputDecoration(
      labelText: label,
      labelStyle: StudioTheme.label,
      isDense: true,
    ),
  ),
);
