import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import 'library.dart';
import 'media.dart';
import 'native_folder.dart';

class MoveResult {
  const MoveResult({required this.moved, required this.destName});
  final int moved;
  final String destName;
}

/// Lets the user pick (or create) a physical folder, then moves the selected
/// photos into it. Needs "All files access" — same permission as renaming a
/// folder on disk.
class MoveFolder {
  /// Shows the folder picker and runs the move. Returns null if the user
  /// cancelled or permission was not granted.
  static Future<MoveResult?> pickAndMove(
    BuildContext context,
    List<AssetEntity> assets,
  ) async {
    if (assets.isEmpty) return null;

    if (!await NativeFolder.hasAllFilesAccess()) {
      if (!context.mounted) return null;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要「所有檔案存取權」'),
          content: const Text(
            '要把照片搬到另一個資料夾，需要先在系統設定開啟「允許存取所有檔案」。'
            '開啟後回到 App 再試一次。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('前往設定'),
            ),
          ],
        ),
      );
      if (go == true) await NativeFolder.requestAllFilesAccess();
      return null;
    }

    if (!context.mounted) return null;
    final target = await showModalBottomSheet<_MoveTarget>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => const _FolderPickerSheet(),
    );
    if (target == null) return null;

    if (!context.mounted) return null;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('正在移動照片…')),
          ],
        ),
      ),
    );

    try {
      final srcPaths = <String>[];
      for (final a in assets) {
        final f = await a.file;
        if (f != null) srcPaths.add(f.path);
      }
      final moved = await NativeFolder.moveFiles(srcPaths, target.dirPath);
      await PhotoLibrary.instance.refresh();
      return MoveResult(moved: moved, destName: target.name);
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }
}

class _MoveTarget {
  const _MoveTarget(this.name, this.dirPath);
  final String name;
  final String dirPath;
}

class _FolderPickerSheet extends StatefulWidget {
  const _FolderPickerSheet();

  @override
  State<_FolderPickerSheet> createState() => _FolderPickerSheetState();
}

class _FolderPickerSheetState extends State<_FolderPickerSheet> {
  List<_MoveTarget> _folders = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: kMediaType,
        hasAll: false,
      );
      final folders = <_MoveTarget>[];
      final seen = <String>{};
      for (final p in paths) {
        final count = await p.assetCountAsync;
        if (count <= 0) continue;
        final first = await p.getAssetListRange(start: 0, end: 1);
        if (first.isEmpty) continue;
        final file = await first.first.file;
        if (file == null) continue;
        final dir = file.parent.path;
        if (!seen.add(dir)) continue;
        folders.add(_MoveTarget(p.name, dir));
      }
      folders.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增資料夾'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '資料夾名稱（會建在 Pictures 底下）',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('建立並移入'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    try {
      final path = await NativeFolder.createFolder(trimmed);
      if (!mounted) return;
      Navigator.of(context).pop(_MoveTarget(trimmed, path));
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('建立失敗：${e.message ?? e.code}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.7;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '移到資料夾',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  onPressed: _create,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('新增'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('讀取資料夾失敗：$_error'));
    }
    if (_folders.isEmpty) {
      return const Center(child: Text('還沒有可選的資料夾，先按右上角新增'));
    }
    return ListView.builder(
      itemCount: _folders.length,
      itemBuilder: (context, i) {
        final f = _folders[i];
        return ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(f.name),
          subtitle: Text(f.dirPath, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => Navigator.of(context).pop(f),
        );
      },
    );
  }
}
