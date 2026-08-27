import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'collections.dart';
import 'folder_covers.dart';
import 'folder_detail.dart';
import 'folder_names.dart';
import 'photo_actions.dart';
import 'selection.dart';
import 'widgets.dart';

/// How the folder list itself is ordered.
enum FolderSort { nameAsc, nameDesc, countDesc, countAsc }

extension on FolderSort {
  String get label => switch (this) {
        FolderSort.nameAsc => '名稱 A→Z',
        FolderSort.nameDesc => '名稱 Z→A',
        FolderSort.countDesc => '數量 多→少',
        FolderSort.countAsc => '數量 少→多',
      };
}

class _Folder {
  _Folder(this.path, this.count);
  final AssetPathEntity path;
  final int count;
}

/// Second tab: physical folders (Android buckets), each with a cover +
/// folder name. Cover = the alphabetically-first photo (by filename).
///
/// Long-press a folder to enter selection mode and act on WHOLE albums at
/// once: favorite / mark-hidden / delete every photo they contain.
class FoldersTab extends StatefulWidget {
  const FoldersTab({super.key});

  @override
  State<FoldersTab> createState() => _FoldersTabState();
}

class _FoldersTabState extends State<FoldersTab> {
  static const _prefsKey = 'sort.folders_list';

  final SelectionController _selection = SelectionController();
  List<_Folder> _folders = [];
  FolderSort _sort = FolderSort.nameAsc;
  bool _loading = true;

  // Cache: bucket id -> its cover asset (first photo by filename).
  final Map<String, AssetEntity?> _coverCache = {};

  @override
  void initState() {
    super.initState();
    FolderCovers.map.addListener(_onCoversChanged);
    FolderNames.map.addListener(_rebuild);
    _init();
  }

  @override
  void dispose() {
    FolderCovers.map.removeListener(_onCoversChanged);
    FolderNames.map.removeListener(_rebuild);
    _selection.dispose();
    super.dispose();
  }

  /// A cover was set/cleared elsewhere: drop the cache so covers reload.
  void _onCoversChanged() {
    _coverCache.clear();
    if (mounted) setState(() {});
  }

  /// A custom folder name changed elsewhere: just repaint the labels.
  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    _sort = FolderSort.values
        .where((s) => s.name == saved)
        .followedBy([FolderSort.nameAsc]).first;
    await _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      hasAll: false,
    );
    final folders = <_Folder>[];
    for (final p in paths) {
      final count = await p.assetCountAsync;
      if (count > 0) folders.add(_Folder(p, count));
    }
    _coverCache.clear();
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _loading = false;
    });
  }

  Future<void> _changeSort(FolderSort s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, s.name);
    setState(() => _sort = s);
  }

  List<_Folder> get _sorted {
    final list = List<_Folder>.from(_folders);
    switch (_sort) {
      case FolderSort.nameAsc:
        list.sort((a, b) =>
            a.path.name.toLowerCase().compareTo(b.path.name.toLowerCase()));
      case FolderSort.nameDesc:
        list.sort((a, b) =>
            b.path.name.toLowerCase().compareTo(a.path.name.toLowerCase()));
      case FolderSort.countDesc:
        list.sort((a, b) => b.count.compareTo(a.count));
      case FolderSort.countAsc:
        list.sort((a, b) => a.count.compareTo(b.count));
    }
    return list;
  }

  /// The folder's cover: the user-chosen photo if one is set, otherwise the
  /// first photo ordered by filename A→Z.
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

  // ---- Whole-album selection actions -------------------------------------

  List<_Folder> get _selectedFolders =>
      _folders.where((f) => _selection.ids.contains(f.path.id)).toList();

  /// Every photo id contained in the currently selected folders.
  Future<List<AssetEntity>> _collectAssets(List<_Folder> folders) async {
    final all = <AssetEntity>[];
    for (final f in folders) {
      final count = await f.path.assetCountAsync;
      all.addAll(await f.path.getAssetListRange(start: 0, end: count));
    }
    return all;
  }

  /// Runs [task] behind a blocking progress dialog (album scans can be slow).
  Future<T?> _withProgress<T>(String message, Future<T> Function() task) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
    try {
      return await task();
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _favoriteSelected() async {
    final folders = _selectedFolders;
    final assets =
        await _withProgress('讀取相簿中…', () => _collectAssets(folders));
    if (assets == null) return;
    await AppCollections.setFavorite(assets.map((a) => a.id), true);
    _selection.clear();
    _snack('已把 ${folders.length} 個相簿、共 ${assets.length} 張加入最愛');
  }

  Future<void> _hideSelected() async {
    final folders = _selectedFolders;
    final assets =
        await _withProgress('讀取相簿中…', () => _collectAssets(folders));
    if (assets == null) return;
    await AppCollections.setHidden(assets.map((a) => a.id), true);
    _selection.clear();
    _snack('已標記隱藏 ${folders.length} 個相簿、共 ${assets.length} 張');
  }

  Future<void> _deleteSelected() async {
    final folders = _selectedFolders;
    final total = folders.fold<int>(0, (sum, f) => sum + f.count);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除整個相簿？'),
        content: Text(
          '將永久刪除 ${folders.length} 個相簿裡的約 $total 張照片，'
          '此動作無法復原。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final assets =
        await _withProgress('讀取相簿中…', () => _collectAssets(folders));
    if (assets == null) return;
    // Android 11+ shows its own confirmation; deleted = ids actually removed.
    final deleted = await PhotoActions.delete(assets);
    _selection.clear();
    if (deleted.isNotEmpty) {
      await _reload();
      _snack('已刪除 ${deleted.length} 張照片');
    }
  }

  Future<void> _selectAll() async {
    for (final f in _sorted) {
      if (!_selection.isSelected(f.path.id)) _selection.toggle(f.path.id);
    }
  }

  PreferredSizeWidget _selectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _selection.clear,
      ),
      title: Text('已選 ${_selection.count} 個相簿'),
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all),
          tooltip: '全選',
          onPressed: _selectAll,
        ),
        IconButton(
          icon: const Icon(Icons.favorite_border),
          tooltip: '整個相簿加入最愛',
          onPressed: _selection.count == 0 ? null : _favoriteSelected,
        ),
        IconButton(
          icon: const Icon(Icons.visibility_off_outlined),
          tooltip: '整個相簿標記隱藏',
          onPressed: _selection.count == 0 ? null : _hideSelected,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: '刪除整個相簿',
          onPressed: _selection.count == 0 ? null : _deleteSelected,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _selection,
      builder: (context, _) {
        return Scaffold(
          appBar: _selection.active
              ? _selectionAppBar()
              : AppBar(
                  title: const Text('資料夾'),
                  actions: [
                    PopupMenuButton<FolderSort>(
                      icon: const Icon(Icons.sort),
                      tooltip: '排序：${_sort.label}',
                      onSelected: _changeSort,
                      itemBuilder: (context) => [
                        for (final s in FolderSort.values)
                          PopupMenuItem(
                            value: s,
                            child: Row(
                              children: [
                                Icon(
                                  s == _sort
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: 18,
                                ),
                                const SizedBox(width: 10),
                                Text(s.label),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : _folders.isEmpty
                  ? const Center(child: Text('沒有找到資料夾'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.82,
                      ),
                      itemCount: _sorted.length,
                      itemBuilder: (context, i) {
                        final folder = _sorted[i];
                        return _FolderCard(
                          folder: folder.path,
                          count: folder.count,
                          coverLoader: () => _cover(folder.path),
                          selection: _selection,
                          onReturn: _reload,
                        );
                      },
                    ),
        );
      },
    );
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.folder,
    required this.count,
    required this.coverLoader,
    required this.selection,
    required this.onReturn,
  });

  final AssetPathEntity folder;
  final int count;
  final Future<AssetEntity?> Function() coverLoader;
  final SelectionController selection;
  final Future<void> Function() onReturn;

  @override
  Widget build(BuildContext context) {
    final selected = selection.isSelected(folder.id);
    return GestureDetector(
      onTap: selection.active
          ? () => selection.toggle(folder.id)
          : () => Navigator.of(context)
              .push(MaterialPageRoute(
                builder: (_) => FolderDetailPage(folder: folder),
              ))
              .then((_) => onReturn()),
      onLongPress: () => selection.enter(folder.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FutureBuilder<AssetEntity?>(
                    future: coverLoader(),
                    builder: (context, snap) {
                      final cover = snap.data;
                      if (cover == null) {
                        return Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: const Icon(Icons.folder_outlined, size: 36),
                        );
                      }
                      return PhotoThumb(asset: cover, side: 400);
                    },
                  ),
                  if (selection.active)
                    Container(
                      color: selected
                          ? Colors.black.withValues(alpha: 0.35)
                          : Colors.black.withValues(alpha: 0.05),
                      alignment: Alignment.topRight,
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                ],
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
