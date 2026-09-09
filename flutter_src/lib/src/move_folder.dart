import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import 'folder_covers.dart';
import 'folder_names.dart';
import 'library.dart';
import 'media.dart';
import 'native_folder.dart';
import 'widgets.dart';

class MoveResult {
  const MoveResult({required this.moved, required this.destName});
  final int moved;
  final String destName;
}

/// Lets the user pick (or create) a physical folder, then moves the selected
/// photos into it. Needs All files access — same permission as renaming a
/// folder on disk.
class MoveFolder {
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
    final target = await Navigator.of(context).push<_MoveTarget>(
      MaterialPageRoute(builder: (_) => const _FolderPickerPage()),
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

class _PickerFolder {
  _PickerFolder(this.path, this.count);
  final AssetPathEntity path;
  final int count;
}

/// Full-screen picker that mirrors the Folders tab: cover grid + search.
class _FolderPickerPage extends StatefulWidget {
  const _FolderPickerPage();

  @override
  State<_FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends State<_FolderPickerPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final Map<String, AssetEntity?> _coverCache = {};
  List<_PickerFolder> _folders = [];
  bool _loading = true;
  bool _searching = false;
  String _query = '';
  String? _error;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _displayName(AssetPathEntity path) =>
      FolderNames.nameOf(path.id) ?? path.name;

  List<_PickerFolder> get _visible {
    final q = _query.trim().toLowerCase();
    final list = _folders.where((f) {
      if (q.isEmpty) return true;
      return _displayName(f.path).toLowerCase().contains(q) ||
          f.path.name.toLowerCase().contains(q);
    }).toList();
    list.sort((a, b) => _displayName(a.path)
        .toLowerCase()
        .compareTo(_displayName(b.path).toLowerCase()));
    return list;
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
      final folders = <_PickerFolder>[];
      for (final p in paths) {
        final count = await p.assetCountAsync;
        if (count > 0) folders.add(_PickerFolder(p, count));
      }
      _coverCache.clear();
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

  Future<AssetEntity?> _cover(AssetPathEntity path) async {
    if (_coverCache.containsKey(path.id)) return _coverCache[path.id];
    final count = await path.assetCountAsync;
    final assets = await path.getAssetListRange(start: 0, end: count);

    AssetEntity? cover;
    final chosenId = FolderCovers.coverOf(path.id);
    if (chosenId != null) {
      for (final a in assets) {
        if (a.id == chosenId) {
          cover = a;
          break;
        }
      }
    }
    if (cover == null) {
      assets.sort((a, b) => (a.title ?? '')
          .toLowerCase()
          .compareTo((b.title ?? '').toLowerCase()));
      cover = assets.isEmpty ? null : assets.first;
    }
    _coverCache[path.id] = cover;
    return cover;
  }

  Future<void> _pick(_PickerFolder folder) async {
    final first = await folder.path.getAssetListRange(start: 0, end: 1);
    if (!mounted) return;
    if (first.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('這個資料夾是空的')),
      );
      return;
    }
    final file = await first.first.file;
    if (!mounted) return;
    if (file == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('找不到這個資料夾的實體路徑')),
      );
      return;
    }
    Navigator.of(context).pop(
      _MoveTarget(_displayName(folder.path), file.parent.path),
    );
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

  void _startSearch() => setState(() => _searching = true);

  void _stopSearch() {
    _searchCtrl.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  PreferredSizeWidget _appBar() {
    if (_searching) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _stopSearch,
        ),
        title: TextField(
          controller: _searchCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '搜尋資料夾名稱',
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: '清除',
              onPressed: () {
                _searchCtrl.clear();
                setState(() => _query = '');
              },
            ),
        ],
      );
    }
    return AppBar(
      title: const Text('移到資料夾'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜尋',
          onPressed: _startSearch,
        ),
        IconButton(
          icon: const Icon(Icons.create_new_folder_outlined),
          tooltip: '新增資料夾',
          onPressed: _create,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(),
      body: _body(),
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
    final visible = _visible;
    if (visible.isEmpty) {
      return const Center(child: Text('找不到符合的資料夾'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final folder = visible[i];
        return _PickerCard(
          folder: folder.path,
          count: folder.count,
          coverLoader: () => _cover(folder.path),
          onTap: () => _pick(folder),
        );
      },
    );
  }
}

class _PickerCard extends StatelessWidget {
  const _PickerCard({
    required this.folder,
    required this.count,
    required this.coverLoader,
    required this.onTap,
  });

  final AssetPathEntity folder;
  final int count;
  final Future<AssetEntity?> Function() coverLoader;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: FutureBuilder<AssetEntity?>(
                future: coverLoader(),
                builder: (context, snap) {
                  final cover = snap.data;
                  if (cover == null) {
                    return Container(
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.folder_outlined, size: 36),
                    );
                  }
                  return PhotoThumb(asset: cover, side: 400);
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            FolderNames.nameOf(folder.id) ?? folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          Text(
            '$count 張',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
