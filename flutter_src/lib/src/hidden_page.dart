import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'collections.dart';
import 'grid_columns.dart';
import 'media.dart';
import 'photo_grid.dart';
import 'selection.dart';
import 'viewer.dart';

/// Shows the photos the user has hidden, so they can review or un-hide them.
class HiddenPage extends StatefulWidget {
  const HiddenPage({super.key});

  @override
  State<HiddenPage> createState() => _HiddenPageState();
}

class _HiddenPageState extends State<HiddenPage> {
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
    final list =
        _all.where((a) => AppCollections.isHidden(a.id)).toList();
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
      animation: Listenable.merge(
          [_selection, AppCollections.hidden, GridColumns.count]),
      builder: (context, _) {
        final visible = _visible;
        final selected =
            visible.where((a) => _selection.ids.contains(a.id)).toList();
        return Scaffold(
          appBar: _selection.active
              ? AppBar(
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _selection.clear,
                  ),
                  title: Text('已選 ${_selection.count}'),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.visibility),
                      tooltip: '取消隱藏',
                      onPressed: () async {
                        await AppCollections.setHidden(_selection.ids, false);
                        _selection.clear();
                      },
                    ),
                  ],
                )
              : AppBar(title: const Text('隱藏項目')),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : visible.isEmpty
                  ? const Center(child: Text('沒有隱藏的照片'))
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
