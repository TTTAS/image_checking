import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'collections.dart';
import 'grid_columns.dart';
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
          [_selection, AppCollections.hidden, GridColumns.count]),
      builder: (context, _) {
        final visible = _visible;
        return Scaffold(
          appBar: _selection.active
              ? selectionAppBar(
                  selection: _selection,
                  all: visible,
                  reload: _reload,
                )
              : AppBar(
                  title: Text(widget.folder.name),
                  actions: [
                    SortMenuButton(current: _sort, onSelected: _changeSort),
                  ],
                ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : visible.isEmpty
                  ? const Center(child: Text('這個資料夾沒有可顯示的照片'))
                  : PinchColumns(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(2),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: GridColumns.count.value,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                        ),
                        itemCount: visible.length,
                        itemBuilder: (context, i) => SelectableThumb(
                          assets: visible,
                          index: i,
                          selection: _selection,
                          onOpen: () => _open(visible, i),
                        ),
                      ),
                    ),
        );
      },
    );
  }
}
