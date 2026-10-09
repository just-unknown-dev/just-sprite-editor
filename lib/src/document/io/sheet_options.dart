/// How frames are laid out on the exported sheet.
enum SheetLayout {
  /// As square as it goes: the default, and the kindest to texture limits.
  grid,

  /// One row.
  horizontal,

  /// One column.
  vertical,
}

class SheetExportOptions {
  const SheetExportOptions({
    this.layout = SheetLayout.grid,
    this.padding = 0,
    this.trim = false,
    this.scale = 1,
  });

  final SheetLayout layout;

  /// Transparent pixels between cells, and around the sheet. One or two stop
  /// a smoothed or scaled sprite bleeding its neighbour in.
  final int padding;

  /// Cut each frame down to its content. The JSON records where it sat, so
  /// it still draws in place.
  final bool trim;

  /// Whole-number upscale of the sheet.
  final int scale;

  SheetExportOptions copyWith({
    SheetLayout? layout,
    int? padding,
    bool? trim,
    int? scale,
  }) => SheetExportOptions(
    layout: layout ?? this.layout,
    padding: padding ?? this.padding,
    trim: trim ?? this.trim,
    scale: scale ?? this.scale,
  );

  Map<String, dynamic> toJson() => {
    'layout': layout.name,
    'padding': padding,
    'trim': trim,
    'scale': scale,
  };

  factory SheetExportOptions.fromJson(Map<String, dynamic> json) =>
      SheetExportOptions(
        layout:
            SheetLayout.values.asNameMap()[json['layout']] ?? SheetLayout.grid,
        padding: ((json['padding'] as num?)?.toInt() ?? 1).clamp(0, 16),
        trim: json['trim'] as bool? ?? false,
        scale: ((json['scale'] as num?)?.toInt() ?? 1).clamp(1, 16),
      );
}
