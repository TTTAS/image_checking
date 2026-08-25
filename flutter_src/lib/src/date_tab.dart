import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'sort.dart';
import 'viewer.dart';
import 'widgets.dart';

/// First tab: every photo in the library, grouped by day when sorted by date.
class DateTab extends StatefulWidget {
  const DateTab({super.key});

  @override
  State<DateTab> createState() => _DateTabState();
}

class _DateTabState extends State<DateTab> {
  static const _prefsKey = 'date';
  static const _fallback = SortOption(SortField.date, SortDir.desc);

  List<AssetEntity> _all = [];
  Map<String, int> _sizes = {};
  SortOption _sort = _fallback;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _sort = await SortStore.load(_prefsKey, _fallback);
    final paths = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.image,
    );
    if (paths.isEmpty) {
      setState(() {
        _all = [];
        _loading = false;
      });
      return;
    }
    final all = paths.first;
    final count = await all.assetCountAsync;
    final assets = await all.getAssetListRange(start: 0, end: count);
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
        title: const Text('日期'),
        actions: [SortMenuButton(current: _sort, onSelected: _changeSort)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : sorted.isEmpty
              ? const Center(child: Text('沒有找到照片'))
              : _sort.groupsByDay
                  ? _GroupedByDay(assets: sorted)
                  : _FlatGrid(assets: sorted),
    );
  }
}

/// A plain 3-column grid (used when sorting by name or size).
class _FlatGrid extends StatelessWidget {
  const _FlatGrid({required this.assets});
  final List<AssetEntity> assets;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: assets.length,
      itemBuilder: (context, i) => _ThumbTile(assets: assets, index: i),
    );
  }
}

/// Grouped by day with sticky-ish date headers (used when sorting by date).
class _GroupedByDay extends StatelessWidget {
  const _GroupedByDay({required this.assets});
  final List<AssetEntity> assets;

  @override
  Widget build(BuildContext context) {
    // Group consecutive photos by their calendar day, preserving order.
    final groups = <String, List<AssetEntity>>{};
    final globalIndex = <String, List<int>>{};
    for (var i = 0; i < assets.length; i++) {
      final d = assets[i].createDateTime;
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      groups.putIfAbsent(key, () => []).add(assets[i]);
      globalIndex.putIfAbsent(key, () => []).add(i);
    }

    final slivers = <Widget>[];
    for (final entry in groups.entries) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
            child: Text(
              entry.key,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
      final indices = globalIndex[entry.key]!;
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => _ThumbTile(
                assets: assets,
                index: indices[i],
              ),
              childCount: entry.value.length,
            ),
          ),
        ),
      );
    }
    return CustomScrollView(slivers: slivers);
  }
}

/// One thumbnail that opens the full-screen viewer at its global index.
class _ThumbTile extends StatelessWidget {
  const _ThumbTile({required this.assets, required this.index});
  final List<AssetEntity> assets;
  final int index;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ViewerPage(assets: assets, initialIndex: index),
        ),
      ),
      child: PhotoThumb(asset: assets[index]),
    );
  }
}
