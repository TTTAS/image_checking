import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'collections.dart';
import 'grid_columns.dart';
import 'hidden_page.dart';
import 'media.dart';
import 'photo_grid.dart';
import 'selection.dart';
import 'sort.dart';
import 'viewer.dart';
import 'widgets.dart';

/// First tab: every photo in the library, grouped by day when sorted by date.
/// Hidden photos are filtered out. Long-press a photo for multi-select.
class DateTab extends StatefulWidget {
  const DateTab({super.key});

  @override
  State<DateTab> createState() => _DateTabState();
}

class _DateTabState extends State<DateTab> {
  static const _prefsKey = 'date';
  static const _fallback = SortOption(SortField.date, SortDir.desc);

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
    final shown =
        _all.where((a) => !AppCollections.isHidden(a.id)).toList();
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
                  title: const Text('日期'),
                  actions: [
                    SortMenuButton(current: _sort, onSelected: _changeSort),
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'hidden') {
                          Navigator.of(context)
                              .push(MaterialPageRoute(
                                builder: (_) => const HiddenPage(),
                              ))
                              .then((_) => _reload());
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'hidden',
                          child: Text('隱藏項目'),
                        ),
                      ],
                    ),
                  ],
                ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : visible.isEmpty
                  ? const Center(child: Text('沒有找到照片'))
                  : PinchColumns(
                      child: _sort.groupsByDay
                          ? _GroupedByDay(
                              assets: visible,
                              columns: GridColumns.count.value,
                              selection: _selection,
                              onOpen: _open,
                            )
                          : _FlatGrid(
                              assets: visible,
                              columns: GridColumns.count.value,
                              selection: _selection,
                              onOpen: _open,
                            ),
                    ),
        );
      },
    );
  }
}

class _FlatGrid extends StatelessWidget {
  const _FlatGrid({
    required this.assets,
    required this.columns,
    required this.selection,
    required this.onOpen,
  });

  final List<AssetEntity> assets;
  final int columns;
  final SelectionController selection;
  final void Function(List<AssetEntity>, int) onOpen;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: assets.length,
      itemBuilder: (context, i) => SelectableThumb(
        assets: assets,
        index: i,
        selection: selection,
        onOpen: () => onOpen(assets, i),
      ),
    );
  }
}

class _GroupedByDay extends StatelessWidget {
  const _GroupedByDay({
    required this.assets,
    required this.columns,
    required this.selection,
    required this.onOpen,
  });

  final List<AssetEntity> assets;
  final int columns;
  final SelectionController selection;
  final void Function(List<AssetEntity>, int) onOpen;

  @override
  Widget build(BuildContext context) {
    // Group by calendar day, preserving the (already sorted) order and each
    // photo's global index into [assets] (used by the viewer).
    final order = <String>[];
    final counts = <String, int>{};
    final firstIndex = <String, int>{};
    for (var i = 0; i < assets.length; i++) {
      final d = assets[i].createDateTime;
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      if (!counts.containsKey(key)) {
        order.add(key);
        firstIndex[key] = i;
        counts[key] = 0;
      }
      counts[key] = counts[key]! + 1;
    }

    final slivers = <Widget>[];
    for (final key in order) {
      final start = firstIndex[key]!;
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
            child: Text(
              key,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final globalIndex = start + i;
                return SelectableThumb(
                  assets: assets,
                  index: globalIndex,
                  selection: selection,
                  onOpen: () => onOpen(assets, globalIndex),
                );
              },
              childCount: counts[key]!,
            ),
          ),
        ),
      );
    }
    return CustomScrollView(slivers: slivers);
  }
}
