import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_detail.dart';
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
class FoldersTab extends StatefulWidget {
  const FoldersTab({super.key});

  @override
  State<FoldersTab> createState() => _FoldersTabState();
}

class _FoldersTabState extends State<FoldersTab> {
  static const _prefsKey = 'sort.folders_list';

  List<_Folder> _folders = [];
  FolderSort _sort = FolderSort.nameAsc;
  bool _loading = true;

  // Cache: bucket id -> its cover asset (first photo by filename).
  final Map<String, AssetEntity?> _coverCache = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    _sort = FolderSort.values
        .where((s) => s.name == saved)
        .followedBy([FolderSort.nameAsc]).first;

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      hasAll: false,
    );
    final folders = <_Folder>[];
    for (final p in paths) {
      final count = await p.assetCountAsync;
      if (count > 0) folders.add(_Folder(p, count));
    }
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

  /// First photo of a folder ordered by filename A→Z, used as the cover.
  Future<AssetEntity?> _cover(AssetPathEntity path) async {
    if (_coverCache.containsKey(path.id)) return _coverCache[path.id];
    final count = await path.assetCountAsync;
    final assets = await path.getAssetListRange(start: 0, end: count);
    assets.sort((a, b) =>
        (a.title ?? '').toLowerCase().compareTo((b.title ?? '').toLowerCase()));
    final cover = assets.isEmpty ? null : assets.first;
    _coverCache[path.id] = cover;
    return cover;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
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
                    );
                  },
                ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.folder,
    required this.count,
    required this.coverLoader,
  });

  final AssetPathEntity folder;
  final int count;
  final Future<AssetEntity?> Function() coverLoader;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => FolderDetailPage(folder: folder)),
      ),
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
            folder.name,
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
