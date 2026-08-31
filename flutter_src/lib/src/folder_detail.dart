import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import 'collections.dart';
import 'folder_covers.dart';
import 'folder_names.dart';
import 'grid_columns.dart';
import 'native_folder.dart';
import 'photo_grid.dart';
import 'selection.dart';
import 'sort.dart';
import 'viewer.dart';
import 'widgets.dart';

/// Photos inside one folder. Default order is filename A→Z; the top-right menu
/// can re-sort by date / name / size. Hidden photos are filtered out.
class FolderDetailPage extends StatefulWidget {
  const FolderDetailPage({super.key, required this.folder});

  final AssetPathEntity folder;

  @override
  State<FolderDetailPage> createState() => _FolderDetailPageState();
}

class _FolderDetailPageState extends State<FolderDetailPage> {
  static const _prefsKey = 'folder_photos';
  static const _fallback = SortOption(SortField.name, SortDir.asc);

  final SelectionController _selection = SelectionController();
  List<AssetEntity> _all = [];
  Map<String, int> _sizes = {};
  SortOption _sort = _fallback;
  bool _loading = true;
  bool _pickingCover = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _sort = await SortStore.load(_prefsKey, _fallback);
    await _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    // Re-resolve the folder so counts are fresh after deletions.
    final count = await widget.folder.assetCountAsync;
    final assets = await widget.folder.getAssetListRange(start: 0, end: count);
    if (_sort.field == SortField.size) {
      _sizes = await loadFileSizes(assets);
    }
    if (!mounted) return;
    setState(() {
      _all = assets;
      _loading = false;
    });
  }

  Future<void> _changeSort(SortOption option) async {
    setState(() => _loading = true);
    if (option.field == SortField.size && _sizes.isEmpty) {
      _sizes = await loadFileSizes(_all);
    }
    await SortStore.save(_prefsKey, option);
    if (!mounted) return;
    setState(() {
      _sort = option;
      _loading = false;
    });
  }

  List<AssetEntity> get _visible {
    final shown = _all.where((a) => !AppCollections.isHidden(a.id)).toList();
    return sortAssets(shown, _sort, sizeOf: _sizes);
  }

  void _open(List<AssetEntity> assets, int index) {
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => ViewerPage(assets: assets, initialIndex: index),
        ))
        .then((_) => _reload());
  }

  Future<void> _setCover(AssetEntity asset) async {
    await FolderCovers.set(widget.folder.id, asset.id);
    if (!mounted) return;
    setState(() => _pickingCover = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已設為資料夾封面')));
  }

  Future<void> _clearCover() async {
    await FolderCovers.clear(widget.folder.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已恢復預設封面')));
  }

  Future<void> _rename() async {
    final controller = TextEditingController(
      text: FolderNames.nameOf(widget.folder.id) ?? widget.folder.name,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新命名資料夾'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '輸入顯示名稱'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('確定'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final trimmed = name.trim();
    // Empty or same as the real folder name → drop the custom alias.
    if (trimmed.isEmpty || trimmed == widget.folder.name) {
      await FolderNames.clear(widget.folder.id);
    } else {
      await FolderNames.set(widget.folder.id, trimmed);
    }
    if (mounted) setState(() {});
  }

  /// The real on-disk directory of this folder, taken from any photo in it.
  Future<String?> _folderDirPath() async {
    for (final a in _all) {
      final f = await a.file;
      if (f != null) return f.parent.path;
    }
    return null;
  }

  /// Renames the actual folder on disk (needs All-files-access), not just the
  /// app-local alias.
  Future<void> _renamePhysical() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    if (!await NativeFolder.hasAllFilesAccess()) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要「所有檔案存取權」'),
          content: const Text(
            '要真的改掉手機上的資料夾名稱，需要先在系統設定開啟「允許存取所有檔案」。'
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
      return;
    }

    final dirPath = await _folderDirPath();
    if (dirPath == null) {
      messenger.showSnackBar(const SnackBar(content: Text('找不到資料夾的實體路徑')));
      return;
    }
    if (!mounted) return;

    final controller = TextEditingController(text: widget.folder.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('改手機資料夾名稱'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '新的資料夾名稱'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('改名'),
          ),
        ],
      ),
    );
    if (newName == null) return;
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == widget.folder.name) return;

    try {
      await NativeFolder.renameFolder(dirPath, trimmed);
      // Real name changed → any app-local alias is now redundant.
      await FolderNames.clear(widget.folder.id);
      messenger.showSnackBar(SnackBar(content: Text('已改名為「$trimmed」')));
      navigator.pop(); // back to the folder list, which reloads on return
    } on PlatformException catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('改名失敗：${e.message ?? e.code}')));
    }
  }

  PreferredSizeWidget _appBar(List<AssetEntity> visible) {
    if (_selection.active) {
      return selectionAppBar(
        selection: _selection,
        all: visible,
        reload: _reload,
      );
    }
    if (_pickingCover) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _pickingCover = false),
        ),
        title: const Text('點一張照片設為封面'),
      );
    }
    return AppBar(
      title: Text(FolderNames.nameOf(widget.folder.id) ?? widget.folder.name),
      actions: [
        SortMenuButton(current: _sort, onSelected: _changeSort),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'rename') {
              _rename();
            } else if (v == 'rename_real') {
              _renamePhysical();
            } else if (v == 'set') {
              setState(() => _pickingCover = true);
            } else if (v == 'clear') {
              _clearCover();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'rename', child: Text('重新命名（僅 App 內）')),
            const PopupMenuItem(
                value: 'rename_real', child: Text('改手機資料夾名稱（實體）')),
            const PopupMenuItem(value: 'set', child: Text('設定封面照片')),
            if (FolderCovers.coverOf(widget.folder.id) != null)
              const PopupMenuItem(value: 'clear', child: Text('恢復預設封面')),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
          [_selection, AppCollections.hidden, GridColumns.count]),
      builder: (context, _) {
        final visible = _visible;
        return Scaffold(
          appBar: _appBar(visible),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : visible.isEmpty
                  ? const Center(child: Text('這個資料夾沒有可顯示的照片'))
                  : Column(
                      children: [
                        if (_pickingCover)
                          Container(
                            width: double.infinity,
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            child: const Text('選一張照片作為這個資料夾的封面'),
                          ),
                        Expanded(
                          child: PinchColumns(
                            child: GridView.builder(
                              padding: const EdgeInsets.all(2),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: GridColumns.count.value,
                                crossAxisSpacing: 2,
                                mainAxisSpacing: 2,
                              ),
                              itemCount: visible.length,
                              itemBuilder: (context, i) => SelectableThumb(
                                assets: visible,
                                index: i,
                                selection: _selection,
                                onOpen: () => _pickingCover
                                    ? _setCover(visible[i])
                                    : _open(visible, i),
                              ),
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
