import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'sort.dart';
import 'viewer.dart';
import 'widgets.dart';

/// Photos inside one folder. Default order is filename A→Z (matching the
/// cover rule); the top-right menu can re-sort by date / name / size.
class FolderDetailPage extends StatefulWidget {
  const FolderDetailPage({super.key, required this.folder});

  final AssetPathEntity folder;

  @override
  State<FolderDetailPage> createState() => _FolderDetailPageState();
}

class _FolderDetailPageState extends State<FolderDetailPage> {
  static const _fallback = SortOption(SortField.name, SortDir.asc);

  List<AssetEntity> _all = [];
  Map<String, int> _sizes = {};
  SortOption _sort = _fallback;
  bool _loading = true;

  String get _prefsKey => 'folder_photos';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _sort = await SortStore.load(_prefsKey, _fallback);
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

  @override
  Widget build(BuildContext context) {
    final sorted = sortAssets(_all, _sort, sizeOf: _sizes);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folder.name),
        actions: [SortMenuButton(current: _sort, onSelected: _changeSort)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : sorted.isEmpty
              ? const Center(child: Text('這個資料夾沒有照片'))
              : GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                  ),
                  itemCount: sorted.length,
                  itemBuilder: (context, i) => GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ViewerPage(assets: sorted, initialIndex: i),
                      ),
                    ),
                    child: PhotoThumb(asset: sorted[i]),
                  ),
                ),
    );
  }
}
