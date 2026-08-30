import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'collections.dart';
import 'grid_columns.dart';
import 'media.dart';
import 'photo_grid.dart';
import 'selection.dart';
import 'viewer.dart';

/// Third tab: photos the user marked as favorite (newest first).
class FavoritesTab extends StatefulWidget {
  const FavoritesTab({super.key});

  @override
  State<FavoritesTab> createState() => _FavoritesTabState();
}

class _FavoritesTabState extends State<FavoritesTab> {
  final SelectionController _selection = SelectionController();
  List<AssetEntity> _all = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final paths = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: kMediaType,
    );
    var assets = <AssetEntity>[];
    if (paths.isNotEmpty) {
      final all = paths.first;
      final count = await all.assetCountAsync;
      assets = await all.getAssetListRange(start: 0, end: count);
    }
    if (!mounted) return;
    setState(() {
      _all = assets;
      _loading = false;
    });
  }

  List<AssetEntity> get _visible {
    final list = _all
        .where((a) =>
            AppCollections.isFavorite(a.id) && !AppCollections.isHidden(a.id))
        .toList();
    list.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    return list;
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
      animation: Listenable.merge([
        _selection,
        AppCollections.favorites,
        AppCollections.hidden,
        GridColumns.count,
      ]),
      builder: (context, _) {
        final visible = _visible;
        return Scaffold(
          appBar: _selection.active
              ? selectionAppBar(
                  selection: _selection,
                  all: visible,
                  reload: _reload,
                )
              : AppBar(title: const Text('我的最愛')),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : visible.isEmpty
                  ? const Center(child: Text('還沒有最愛的照片\n在照片上點愛心即可加入'))
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
