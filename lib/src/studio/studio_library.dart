/// The project's sprites, and the way in for one from outside it.
///
/// The studio opens whatever it is handed — from the Assets dock, or a
/// path on the command line — which is no use when what you want is
/// *another* sprite in the same project. This lists them.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'studio_panels.dart';
import 'studio_theme.dart';

/// What can be brought in from outside: anything the studio can read.
const List<String> kImportExtensions = ['jsprite', 'png', 'aseprite', 'ase'];

/// What the list offers. A `.png` beside a project is that project's
/// export, not a second sprite, and listing both said the same sprite
/// twice.
const String kProjectExtension = 'jsprite';

/// One sprite file in the project.
class SpriteAsset {
  const SpriteAsset({required this.path, required this.bytes});

  /// Project-relative, with forward slashes — what the studio opens by.
  final String path;

  /// Size on disk, for the line under the name.
  final int bytes;

  String get name => path.split('/').last;
  String get folder {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? '' : path.substring(0, cut);
  }
}

/// Finds the sprites in a project, and brings new ones into it.
class SpriteLibrary {
  SpriteLibrary({required this.root, this.folder = 'assets'});

  /// The project root, absolute.
  final String root;

  /// Where under it to look. Everything else — `build`, `.dart_tool` and
  /// the rest — is somebody else's business and slow to walk.
  final String folder;

  /// Every sprite under [folder], by path.
  ///
  /// Hidden folders and the editor's own trash are skipped, so a deleted
  /// sprite does not come back as something to open.
  List<SpriteAsset> scan() {
    final dir = Directory('$root/$folder');
    final List<FileSystemEntity> found;
    try {
      if (!dir.existsSync()) return const [];
      found = dir.listSync(recursive: true, followLinks: false);
    } on FileSystemException {
      // No sprites to offer, which is not a reason to fail the studio.
      return const [];
    }
    final out = <SpriteAsset>[];
    for (final entity in found) {
      if (entity is! File) continue;
      final path = entity.path.replaceAll(r'\', '/');
      final relative = path.startsWith('$root/')
          ? path.substring(root.length + 1)
          : path;
      if (relative.split('/').any((part) => part.startsWith('.'))) continue;
      final dot = relative.lastIndexOf('.');
      if (dot < 0) continue;
      if (relative.substring(dot + 1) != kProjectExtension) continue;
      out.add(SpriteAsset(path: relative, bytes: entity.statSync().size));
    }
    out.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return out;
  }

  /// Copies [from] into [into], under a name nothing else has, and gives
  /// back its project-relative path.
  ///
  /// Copied rather than opened where it lies: a sprite the project does
  /// not hold is one the game cannot load.
  Future<String> import(String from, {required String into}) async {
    final source = File(from);
    final folder = Directory('$root/$into');
    if (!folder.existsSync()) folder.createSync(recursive: true);
    final name = from.replaceAll(r'\', '/').split('/').last;
    final unique = _free(name, in_: '$root/$into');
    await source.copy('$root/$into/$unique');
    return '$into/$unique';
  }

  /// [name], or `name_2`, `name_3`… when it is taken.
  String _free(String name, {required String in_}) {
    if (!File('$in_/$name').existsSync()) return name;
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    final ext = dot < 0 ? '' : name.substring(dot);
    for (var i = 2; i < 1000; i++) {
      if (!File('$in_/${stem}_$i$ext').existsSync()) return '${stem}_$i$ext';
    }
    return '${stem}_${DateTime.now().millisecondsSinceEpoch}$ext';
  }
}

/// Asks for a sprite anywhere on disk. Null when nothing was chosen.
Future<String?> pickSpriteFile() async {
  final file = await openFile(
    acceptedTypeGroups: [
      const XTypeGroup(label: 'Sprites', extensions: kImportExtensions),
    ],
  );
  return file?.path;
}

/// The project's sprites, above the colour: what it holds, and a way in
/// for what it does not.
class SpriteLibraryPanel extends StatelessWidget {
  const SpriteLibraryPanel({
    super.key,
    required this.assets,
    required this.openPath,
    required this.onOpen,
    required this.onImport,
    required this.onRefresh,
    required this.isOpen,
    required this.onToggle,
    required this.height,
    required this.onResize,
  });

  final List<SpriteAsset> assets;

  /// What is open now, so its row can say so.
  final String? openPath;

  final void Function(SpriteAsset asset) onOpen;
  final VoidCallback onImport;
  final VoidCallback onRefresh;

  /// Whether the section is folded down. Folded, it is one line, and the
  /// colour and the layers have the height.
  final bool isOpen;
  final VoidCallback onToggle;

  /// How tall the list is now. Dragged by the handle under it, the way
  /// the scene tree is sized in the game editor.
  final double height;

  /// Pixels dragged since the last call; down is positive.
  final ValueChanged<double> onResize;

  /// What it opens at, and the least it can be dragged to.
  static const double defaultHeight = 152;
  static const double minHeight = 72;

  @override
  Widget build(BuildContext context) {
    String? folder;
    final rows = <Widget>[];
    for (final asset in assets) {
      if (asset.folder != folder) {
        folder = asset.folder;
        rows.add(_FolderLine(folder));
      }
      rows.add(
        _AssetLine(
          asset: asset,
          isOpen: asset.path == openPath,
          onTap: () => onOpen(asset),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(
          'Sprites',
          actions: [
            if (isOpen)
              _IconButton(
                icon: Icons.refresh,
                tooltip: 'Look again',
                onPressed: onRefresh,
              ),
            _IconButton(
              icon: isOpen ? Icons.expand_less : Icons.expand_more,
              tooltip: isOpen ? 'Fold it away' : "The project's sprites",
              onPressed: onToggle,
            ),
          ],
        ),
        if (isOpen) ...[
          SizedBox(
            height: height,
            child: rows.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        'No sprites in this project yet.',
                        textAlign: TextAlign.center,
                        style: StudioTheme.body.copyWith(fontSize: 11),
                      ),
                    ),
                  )
                : ListView(padding: EdgeInsets.zero, children: rows),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: _ImportButton(onPressed: onImport),
          ),
          _ResizeHandle(onDrag: onResize),
        ],
      ],
    );
  }
}

class _FolderLine extends StatelessWidget {
  const _FolderLine(this.folder);

  final String folder;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 8, 8, 2),
    child: Text(
      folder.isEmpty ? '/' : folder,
      overflow: TextOverflow.ellipsis,
      style: StudioTheme.body.copyWith(fontSize: 9, letterSpacing: 0.4),
    ),
  );
}

class _AssetLine extends StatelessWidget {
  const _AssetLine({
    required this.asset,
    required this.isOpen,
    required this.onTap,
  });

  final SpriteAsset asset;
  final bool isOpen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: isOpen ? StudioTheme.accent.withValues(alpha: 0.18) : null,
      child: Row(
        children: [
          Icon(
            asset.path.endsWith('.jsprite')
                ? Icons.grid_on_rounded
                : Icons.image_outlined,
            size: 13,
            color: StudioTheme.text.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              asset.name,
              overflow: TextOverflow.ellipsis,
              style: StudioTheme.body.copyWith(
                fontSize: 11,
                fontWeight: isOpen ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          Text(
            _size(asset.bytes),
            style: StudioTheme.body.copyWith(fontSize: 9),
          ),
        ],
      ),
    ),
  );

  static String _size(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).round()} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _ImportButton extends StatelessWidget {
  const _ImportButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onPressed,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: StudioTheme.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: StudioTheme.accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.file_upload_outlined, size: 13),
          const SizedBox(width: 6),
          Text('Import…', style: StudioTheme.body.copyWith(fontSize: 11)),
        ],
      ),
    ),
  );
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 13, color: StudioTheme.text),
      ),
    ),
  );
}

/// The line between the sprites and the colour, which can be dragged.
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeRow,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
      child: Container(
        height: 10,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: StudioTheme.border)),
        ),
        child: Container(
          width: 28,
          height: 3,
          decoration: BoxDecoration(
            color: StudioTheme.text.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    ),
  );
}
