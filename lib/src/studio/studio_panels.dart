import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_editor_core/just_editor_core.dart'
    show CommitTextField, EditorKeys;
import 'package:just_signals/just_signals.dart';

import '../document/palettes.dart';
import '../document/pixel_buffer.dart';
import '../document/raster.dart';
import 'studio_session.dart';
import 'studio_theme.dart';

IconData toolIcon(StudioTool tool) => switch (tool) {
  StudioTool.pencil => Icons.edit,
  StudioTool.eraser => Icons.auto_fix_normal,
  StudioTool.fill => Icons.format_color_fill,
  StudioTool.picker => Icons.colorize,
  StudioTool.line => Icons.show_chart,
  StudioTool.rectangle => Icons.crop_square,
  StudioTool.ellipse => Icons.circle_outlined,
  StudioTool.select => Icons.highlight_alt,
  StudioTool.move => Icons.open_with,
};

/// A small square button: an icon, a tooltip, lit when [active].
class StudioIconButton extends StatelessWidget {
  const StudioIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.size = 26,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: const Duration(milliseconds: 400),
    child: Material(
      color: active ? StudioTheme.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(5),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox.square(
          dimension: size,
          child: Icon(
            icon,
            size: size * 0.58,
            color: onTap == null
                ? StudioTheme.textMuted.withValues(alpha: 0.4)
                : active
                ? StudioTheme.accent
                : StudioTheme.text,
          ),
        ),
      ),
    ),
  );
}

/// The bar along the top of the studio and of the animator, laid out as
/// the game editor lays out its own workspaces' headers, so that opened
/// inside it they read as its windows: what it is and which file, a dot
/// while there is work not saved, Save, Undo and Redo, then the tool's own
/// buttons; full screen and close on the right.
///
/// Its own widget rather than the editor's: the studio runs without the
/// editor.
class StudioHeader extends StatelessWidget {
  const StudioHeader({
    super.key,
    required this.icon,
    required this.title,
    this.file,
    this.detail,
    this.dirty = false,
    this.onSave,
    this.saveTooltip = 'Save',
    this.onUndo,
    this.onRedo,
    this.undoLabel,
    this.redoLabel,
    this.tools = const [],
    this.trailing = const [],
    this.fullScreen,
    this.onToggleFullScreen,
    this.onClose,
    this.closeTooltip = 'Close',
  });

  final IconData icon;

  /// What the tool is: "Sprite Studio", "Animator".
  final String title;

  /// The file it has open.
  final String? file;

  /// A word more about it, after the file: the canvas size.
  final String? detail;

  final bool dirty;

  /// Null hides Save.
  final VoidCallback? onSave;
  final String saveTooltip;

  /// Null greys the button out.
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final String? undoLabel;
  final String? redoLabel;

  /// The tool's own buttons, after Undo and Redo.
  final List<Widget> tools;

  /// Before full screen and close.
  final List<Widget> trailing;

  final ValueListenable<bool>? fullScreen;
  final VoidCallback? onToggleFullScreen;

  /// Null hides Close.
  final VoidCallback? onClose;
  final String closeTooltip;

  static const double height = 36;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      color: StudioTheme.panel,
      border: Border(bottom: BorderSide(color: StudioTheme.border)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Icon(icon, size: 16, color: StudioTheme.accent),
              const SizedBox(width: 6),
              Text(
                title,
                style: StudioTheme.body.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (file != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    file!,
                    overflow: TextOverflow.ellipsis,
                    style: StudioTheme.body.copyWith(
                      color: StudioTheme.textMuted,
                    ),
                  ),
                ),
              ],
              if (detail != null) ...[
                const SizedBox(width: 6),
                Text(detail!, style: StudioTheme.label),
              ],
              if (dirty) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Not saved',
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: StudioTheme.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 10),
              if (onSave != null)
                StudioIconButton(
                  icon: Icons.save_outlined,
                  tooltip: '$saveTooltip  (${EditorKeys.withPrimary('S')})',
                  active: dirty,
                  onTap: onSave,
                ),
              StudioIconButton(
                icon: Icons.undo,
                tooltip: undoLabel == null
                    ? 'Undo  (${EditorKeys.withPrimary('Z')})'
                    : 'Undo $undoLabel  (${EditorKeys.withPrimary('Z')})',
                onTap: onUndo,
              ),
              StudioIconButton(
                icon: Icons.redo,
                tooltip: redoLabel == null
                    ? 'Redo  (${EditorKeys.withPrimary('Y')})'
                    : 'Redo $redoLabel  (${EditorKeys.withPrimary('Y')})',
                onTap: onRedo,
              ),
              if (tools.isNotEmpty) ...[
                Container(
                  width: 1,
                  height: 16,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: StudioTheme.border,
                ),
                Flexible(
                  flex: 3,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(mainAxisSize: MainAxisSize.min, children: tools),
                  ),
                ),
              ],
            ],
          ),
        ),
        ...trailing,
        ?FullScreenButton.maybe(
          fullScreen: fullScreen,
          onToggle: onToggleFullScreen,
        ),
        if (onClose != null)
          StudioIconButton(
            icon: Icons.close,
            tooltip: closeTooltip,
            onTap: onClose,
          ),
      ],
    ),
  );
}

/// Fills the editor with this tool, or puts it back in its dialog. Null
/// where the host offers no such choice — the studio run on its own.
class FullScreenButton extends StatelessWidget {
  const FullScreenButton({
    super.key,
    required this.fullScreen,
    required this.onToggle,
  });

  /// The button, or null when there is nothing to toggle.
  static Widget? maybe({
    required ValueListenable<bool>? fullScreen,
    required VoidCallback? onToggle,
  }) => fullScreen == null || onToggle == null
      ? null
      : FullScreenButton(fullScreen: fullScreen, onToggle: onToggle);

  final ValueListenable<bool> fullScreen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: fullScreen,
    builder: (context, filled, _) => StudioIconButton(
      icon: filled ? Icons.fullscreen_exit : Icons.fullscreen,
      tooltip: filled ? 'Leave full screen' : 'Full screen',
      active: filled,
      onTap: onToggle,
    ),
  );
}

/// The tools, in a column down the left edge.
class ToolStrip extends StatelessWidget {
  const ToolStrip({super.key, required this.session});

  final SpriteStudioSession session;

  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    color: StudioTheme.panel,
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: SignalBuilder<StudioTool>(
      signal: session.tool,
      builder: (context, current, _) => Column(
        children: [
          for (final tool in StudioTool.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: StudioIconButton(
                icon: toolIcon(tool),
                tooltip: '${tool.label}  (${tool.key})',
                active: tool == current,
                size: 30,
                onTap: () => session.tool.value = tool,
              ),
            ),
        ],
      ),
    ),
  );
}

/// What the active tool can be set to: brush size, pixel-perfect, symmetry,
/// filled shapes, contiguous fill.
class ToolOptionsBar extends StatelessWidget {
  const ToolOptionsBar({super.key, required this.session});

  final SpriteStudioSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return SignalConsumer(
      signals: [
        s.tool,
        s.brushSize,
        s.pixelPerfect,
        s.symmetry,
        s.filledShapes,
        s.contiguousFill,
        s.showGrid,
        s.zoom,
      ],
      builder: (context, _) {
        final tool = s.tool.value;
        final draws = switch (tool) {
          StudioTool.pencil ||
          StudioTool.eraser ||
          StudioTool.line ||
          StudioTool.rectangle ||
          StudioTool.ellipse => true,
          _ => false,
        };
        final isShape =
            tool == StudioTool.rectangle || tool == StudioTool.ellipse;
        return Container(
          height: 32,
          color: StudioTheme.panelRaised,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Icon(toolIcon(tool), size: 14, color: StudioTheme.accent),
              const SizedBox(width: 6),
              Text(tool.label, style: StudioTheme.body),
              const SizedBox(width: 14),
              if (draws) ...[
                Text('Size', style: StudioTheme.label),
                StudioIconButton(
                  icon: Icons.remove,
                  tooltip: 'Smaller brush  ([)',
                  size: 22,
                  onTap: () =>
                      s.brushSize.value = (s.brushSize.value - 1).clamp(1, 32),
                ),
                SizedBox(
                  width: 18,
                  child: Text(
                    '${s.brushSize.value}',
                    textAlign: TextAlign.center,
                    style: StudioTheme.body,
                  ),
                ),
                StudioIconButton(
                  icon: Icons.add,
                  tooltip: 'Larger brush  (])',
                  size: 22,
                  onTap: () =>
                      s.brushSize.value = (s.brushSize.value + 1).clamp(1, 32),
                ),
                const SizedBox(width: 8),
              ],
              if (tool == StudioTool.pencil || tool == StudioTool.eraser)
                _Toggle(
                  label: 'Pixel-perfect',
                  tooltip: 'Keep one-pixel lines free of doubled corners',
                  value: s.pixelPerfect.value,
                  onChanged: (v) => s.pixelPerfect.value = v,
                ),
              if (isShape)
                _Toggle(
                  label: 'Filled',
                  tooltip: 'Fill the shape instead of outlining it',
                  value: s.filledShapes.value,
                  onChanged: (v) => s.filledShapes.value = v,
                ),
              if (tool == StudioTool.fill)
                _Toggle(
                  label: 'Contiguous',
                  tooltip: 'Off: fill every pixel of that colour in the cel',
                  value: s.contiguousFill.value,
                  onChanged: (v) => s.contiguousFill.value = v,
                ),
              if (draws) ...[
                const SizedBox(width: 8),
                Text('Mirror', style: StudioTheme.label),
                for (final (mode, icon, tip) in const [
                  (Symmetry.horizontal, Icons.flip, 'Mirror left–right'),
                  (
                    Symmetry.vertical,
                    Icons.flip_camera_android,
                    'Mirror top–bottom',
                  ),
                ])
                  StudioIconButton(
                    icon: icon,
                    tooltip: tip,
                    size: 22,
                    active:
                        s.symmetry.value == mode ||
                        s.symmetry.value == Symmetry.both,
                    onTap: () =>
                        s.symmetry.value = _toggleAxis(s.symmetry.value, mode),
                  ),
              ],
              const Spacer(),
              StudioIconButton(
                icon: Icons.grid_on,
                tooltip: 'Pixel grid',
                size: 22,
                active: s.showGrid.value,
                onTap: () => s.showGrid.value = !s.showGrid.value,
              ),
              StudioIconButton(
                icon: Icons.zoom_out,
                tooltip: 'Zoom out  (-)',
                size: 22,
                onTap: () => s.zoomBy(-1),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${(s.zoom.value * 100).round()}%',
                  textAlign: TextAlign.center,
                  style: StudioTheme.label,
                ),
              ),
              StudioIconButton(
                icon: Icons.zoom_in,
                tooltip: 'Zoom in  (+)',
                size: 22,
                onTap: () => s.zoomBy(1),
              ),
            ],
          ),
        );
      },
    );
  }

  static Symmetry _toggleAxis(Symmetry now, Symmetry axis) {
    var h = now == Symmetry.horizontal || now == Symmetry.both;
    var v = now == Symmetry.vertical || now == Symmetry.both;
    if (axis == Symmetry.horizontal) h = !h;
    if (axis == Symmetry.vertical) v = !v;
    return h && v
        ? Symmetry.both
        : h
        ? Symmetry.horizontal
        : v
        ? Symmetry.vertical
        : Symmetry.none;
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.tooltip,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String tooltip;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: const Duration(milliseconds: 400),
    child: InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.check_box : Icons.check_box_outline_blank,
              size: 13,
              color: value ? StudioTheme.accent : StudioTheme.textMuted,
            ),
            const SizedBox(width: 4),
            Text(label, style: StudioTheme.label),
          ],
        ),
      ),
    ),
  );
}

/// A panel's title row.
class PanelHeader extends StatelessWidget {
  const PanelHeader(this.title, {super.key, this.actions = const []});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    height: 26,
    padding: const EdgeInsets.only(left: 8, right: 4),
    color: StudioTheme.panelRaised,
    child: Row(
      children: [
        Expanded(child: Text(title.toUpperCase(), style: StudioTheme.heading)),
        ...actions,
      ],
    ),
  );
}

// ── Colour ───────────────────────────────────────────────────────────────────

/// Primary and secondary colour, an HSV picker for the primary, and the
/// sprite's palette.
class ColorPanel extends StatelessWidget {
  const ColorPanel({super.key, required this.session});

  final SpriteStudioSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return SignalConsumer(
      signals: [s.primary, s.secondary, s.revision],
      builder: (context, _) {
        final hsv = HSVColor.fromColor(Color(s.primary.value));
        void set(HSVColor next) => s.primary.value = next.toColor().toARGB32();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PanelHeader(
              'Colour',
              actions: [
                StudioIconButton(
                  icon: Icons.swap_horiz,
                  tooltip: 'Swap colours  (X)',
                  size: 22,
                  onTap: s.swapColors,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _Swatch(
                        color: s.primary.value,
                        size: 30,
                        tooltip: 'Primary',
                      ),
                      const SizedBox(width: 4),
                      _Swatch(
                        color: s.secondary.value,
                        size: 22,
                        tooltip: 'Secondary (right button)',
                        onTap: s.swapColors,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _HexField(
                          key: ValueKey(s.primary.value),
                          color: s.primary.value,
                          onChanged: (c) => s.primary.value = c,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _GradientSlider(
                    label: 'H',
                    value: hsv.hue / 360,
                    colors: [
                      for (var h = 0; h <= 360; h += 60)
                        HSVColor.fromAHSV(
                          1,
                          h.toDouble() % 360,
                          1,
                          1,
                        ).toColor(),
                    ],
                    onChanged: (v) =>
                        set(hsv.withHue((v * 360).clamp(0, 359.9))),
                  ),
                  _GradientSlider(
                    label: 'S',
                    value: hsv.saturation,
                    colors: [
                      hsv.withSaturation(0).withAlpha(1).toColor(),
                      hsv.withSaturation(1).withAlpha(1).toColor(),
                    ],
                    onChanged: (v) => set(hsv.withSaturation(v)),
                  ),
                  _GradientSlider(
                    label: 'V',
                    value: hsv.value,
                    colors: [
                      Colors.black,
                      hsv.withValue(1).withAlpha(1).toColor(),
                    ],
                    onChanged: (v) => set(hsv.withValue(v)),
                  ),
                  _GradientSlider(
                    label: 'A',
                    value: hsv.alpha,
                    colors: [
                      hsv.withAlpha(0).toColor(),
                      hsv.withAlpha(1).toColor(),
                    ],
                    onChanged: (v) => set(hsv.withAlpha(v)),
                  ),
                ],
              ),
            ),
            PanelHeader(
              'Palette',
              actions: [
                PopupMenuButton<NamedPalette>(
                  tooltip: 'Load a preset palette',
                  color: StudioTheme.panelRaised,
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.palette_outlined,
                    size: 14,
                    color: StudioTheme.text,
                  ),
                  itemBuilder: (context) => [
                    for (final p in Palettes.presets)
                      PopupMenuItem(
                        value: p,
                        height: 28,
                        child: Text(
                          '${p.name}  (${p.colors.length})',
                          style: StudioTheme.body,
                        ),
                      ),
                  ],
                  onSelected: (p) => s.structural(
                    'Load palette',
                    (d) => d.palette
                      ..clear()
                      ..addAll(p.colors),
                  ),
                ),
                StudioIconButton(
                  icon: Icons.add,
                  tooltip: 'Add the primary colour to the palette',
                  size: 22,
                  onTap: () {
                    if (s.document.palette.contains(s.primary.value)) return;
                    s.structural(
                      'Add colour',
                      (d) => d.palette.add(s.primary.value),
                    );
                  },
                ),
                StudioIconButton(
                  icon: Icons.auto_awesome_outlined,
                  tooltip: 'Palette from the colours in this sprite',
                  size: 22,
                  onTap: () => s.structural('Palette from sprite', (d) {
                    final used = Palettes.fromPixels([
                      for (final l in d.layers)
                        for (final f in d.frames) ?d.cel(l.id, f.id),
                    ]);
                    d.palette
                      ..clear()
                      ..addAll(used);
                  }),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: s.document.palette.isEmpty
                  ? Text(
                      'No colours yet. Load a preset, or add the ones you use.',
                      style: StudioTheme.label,
                    )
                  : Wrap(
                      spacing: 2,
                      runSpacing: 2,
                      children: [
                        for (final c in s.document.palette)
                          _Swatch(
                            color: c,
                            size: 18,
                            selected: c == s.primary.value,
                            tooltip: Argb.toHex(c),
                            onTap: () => s.primary.value = c,
                            onSecondaryTap: () => s.secondary.value = c,
                            onLongPress: () => s.structural(
                              'Remove colour',
                              (d) => d.palette.remove(c),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.size,
    required this.tooltip,
    this.selected = false,
    this.onTap,
    this.onSecondaryTap,
    this.onLongPress,
  });

  final int color;
  final double size;
  final String tooltip;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onSecondaryTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: const Duration(milliseconds: 500),
    child: GestureDetector(
      onTap: onTap,
      onSecondaryTap: onSecondaryTap,
      onLongPress: onLongPress,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          // A light ground shows a translucent colour for what it is.
          color: StudioTheme.checkerLight,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: selected ? Colors.white : StudioTheme.border,
            width: selected ? 2 : 1,
          ),
        ),
        foregroundDecoration: BoxDecoration(
          color: Color(color),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}

class _HexField extends StatelessWidget {
  const _HexField({super.key, required this.color, required this.onChanged});

  final int color;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 26,
    // Kept on Enter or on leaving the field — Tab, a click elsewhere. What
    // is not a colour puts back the one it had; so does Esc.
    child: CommitTextField(
      value: Argb.toHex(color),
      accept: (text) => Argb.parseHex(text) != null,
      onCommit: (text) => onChanged(Argb.parseHex(text)!),
      style: TextStyle(
        color: StudioTheme.text,
        fontSize: 11,
        fontFamily: 'monospace',
      ),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: StudioTheme.field,
        contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        border: OutlineInputBorder(
          borderSide: BorderSide(color: StudioTheme.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: StudioTheme.border),
        ),
      ),
    ),
  );
}

class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  final String label;
  final double value;
  final List<Color> colors;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Row(
      children: [
        SizedBox(width: 12, child: Text(label, style: StudioTheme.label)),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              void at(Offset p) =>
                  onChanged((p.dx / box.maxWidth).clamp(0.0, 1.0));
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => at(d.localPosition),
                onHorizontalDragUpdate: (d) => at(d.localPosition),
                child: SizedBox(
                  height: 14,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: StudioTheme.checkerLight,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: StudioTheme.border),
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(3),
                              gradient: LinearGradient(colors: colors),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: (value.clamp(0.0, 1.0) * box.maxWidth) - 3,
                        top: -2,
                        bottom: -2,
                        child: Container(
                          width: 6,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                            border: Border.all(color: Colors.black54),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

// ── Layers ───────────────────────────────────────────────────────────────────

/// The layers, top first as they are drawn, with visibility, lock, opacity
/// and order.
class LayersPanel extends StatelessWidget {
  const LayersPanel({super.key, required this.session});

  final SpriteStudioSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return SignalConsumer(
      signals: [s.revision, s.layerIndex],
      builder: (context, _) {
        final layers = s.document.layers;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PanelHeader(
              'Layers',
              actions: [
                StudioIconButton(
                  icon: Icons.add,
                  tooltip: 'New layer',
                  size: 22,
                  onTap: s.addLayer,
                ),
                StudioIconButton(
                  icon: Icons.copy_all_outlined,
                  tooltip: 'Duplicate layer',
                  size: 22,
                  onTap: s.duplicateLayer,
                ),
                StudioIconButton(
                  icon: Icons.vertical_align_bottom,
                  tooltip: 'Merge down',
                  size: 22,
                  onTap: s.layerIndex.value > 0 ? s.mergeLayerDown : null,
                ),
                StudioIconButton(
                  icon: Icons.arrow_upward,
                  tooltip: 'Move up',
                  size: 22,
                  onTap: () => s.moveLayer(1),
                ),
                StudioIconButton(
                  icon: Icons.arrow_downward,
                  tooltip: 'Move down',
                  size: 22,
                  onTap: () => s.moveLayer(-1),
                ),
                StudioIconButton(
                  icon: Icons.delete_outline,
                  tooltip: 'Delete layer',
                  size: 22,
                  onTap: layers.length > 1 ? s.removeLayer : null,
                ),
              ],
            ),
            for (var i = layers.length - 1; i >= 0; i--)
              _LayerRow(session: s, index: i),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  Text('Opacity', style: StudioTheme.label),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 5,
                        ),
                        overlayShape: SliderComponentShape.noOverlay,
                        activeTrackColor: StudioTheme.accent,
                        inactiveTrackColor: StudioTheme.border,
                        thumbColor: StudioTheme.accent,
                      ),
                      child: Slider(
                        value: s.layer.opacity / 255,
                        // Live while dragging; one undo step when let go.
                        onChanged: (v) {
                          s.layer.opacity = (v * 255).round();
                          s.document.touch();
                          s.changed();
                        },
                        onChangeStart: (_) => _opacityBefore = s.layer.opacity,
                        onChangeEnd: (v) {
                          final after = (v * 255).round();
                          s.layer.opacity = _opacityBefore ?? after;
                          final id = s.layer.id;
                          s.structural(
                            'Layer opacity',
                            (d) => d.layerById(id)?.opacity = after,
                          );
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 30,
                    child: Text(
                      '${(s.layer.opacity / 2.55).round()}%',
                      textAlign: TextAlign.right,
                      style: StudioTheme.label,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static int? _opacityBefore;
}

class _LayerRow extends StatelessWidget {
  const _LayerRow({required this.session, required this.index});

  final SpriteStudioSession session;
  final int index;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final layer = s.document.layers[index];
    final active = index == s.layerIndex.value;
    return InkWell(
      onTap: () => s.layerIndex.value = index,
      onDoubleTap: () => _rename(context),
      child: Container(
        height: 26,
        color: active ? StudioTheme.selected : null,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            StudioIconButton(
              icon: layer.visible ? Icons.visibility : Icons.visibility_off,
              tooltip: layer.visible ? 'Hide' : 'Show',
              size: 22,
              onTap: () => s.structural(
                layer.visible ? 'Hide layer' : 'Show layer',
                (d) => d.layers[index].visible = !layer.visible,
              ),
            ),
            StudioIconButton(
              icon: layer.locked ? Icons.lock : Icons.lock_open,
              tooltip: layer.locked ? 'Unlock' : 'Lock',
              size: 22,
              active: layer.locked,
              onTap: () => s.structural(
                layer.locked ? 'Unlock layer' : 'Lock layer',
                (d) => d.layers[index].locked = !layer.locked,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                layer.name,
                overflow: TextOverflow.ellipsis,
                style: StudioTheme.body.copyWith(
                  color: layer.visible
                      ? StudioTheme.text
                      : StudioTheme.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final name = await promptForText(
      context,
      title: 'Rename layer',
      initial: session.document.layers[index].name,
    );
    if (name == null || name.isEmpty) return;
    session.structural('Rename layer', (d) => d.layers[index].name = name);
  }
}

/// A one-field dialog. Null when cancelled.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: StudioTheme.panel,
      title: Text(title, style: StudioTheme.body.copyWith(fontSize: 13)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: StudioTheme.body,
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
