import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'app.dart';
import 'collections.dart';
import 'grid_columns.dart';
import 'hidden_page.dart';
import 'library.dart';
import 'photo_grid.dart';
import 'selection.dart';
import 'sort.dart';
import 'viewer.dart';
import 'widgets.dart';

/// First tab: every photo in the library, grouped by day when sorted by date.
/// Hidden photos are filtered out. Long-press a photo for multi-select.
class DateTab extends StatefulWidget {
  const DateTab({super.key, required this.scrollToTop});

  final ScrollToTopSignal scrollToTop;

  @override
  State<DateTab> createState() => _DateTabState();
}

class _DateTabState extends State<DateTab> {
  static const _prefsKey = 'date';
  static const _fallback = SortOption(SortField.date, SortDir.desc);

  final SelectionController _selection = SelectionController();
  final ScrollController _scroll = ScrollController();
  final PhotoLibrary _library = PhotoLibrary.instance;
  Map<String, int> _sizes = {};
  SortOption _sort = _fallback;

  /// True only while loading size info for a fresh size-sort (the library's own
  /// first-load spinner is tracked separately by [PhotoLibrary.loading]).
  bool _sortBusy = false;

  // Derived data (the filtered+sorted list and its day sections) is expensive
  // to recompute, so it's cached and only rebuilt when an input that actually
  // affects it changes — not on every rebuild (selection, pinch-zoom, etc).
  List<AssetEntity>? _cachedVisible;
  List<_DaySection> _cachedSections = const [];
  List<AssetEntity>? _keyAssets;
  Set<String>? _keyHidden;
  Map<String, int>? _keySizes;
  SortOption? _keySort;

  @override
  void initState() {
    super.initState();
    widget.scrollToTop.addListener(_scrollToTop);
    _init();
  }

  @override
  void dispose() {
    widget.scrollToTop.removeListener(_scrollToTop);
    _scroll.dispose();
    _selection.dispose();
    super.dispose();
  }

  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _init() async {
    _sort = await SortStore.load(_prefsKey, _fallback);
    if (mounted) setState(() {});
    // Shared, cached scan: the first tab that needs it loads the library once;
    // returning here later reuses the cache instead of rescanning.
    await _library.ensureLoaded();
  }

  Future<void> _changeSort(SortOption option) async {
    if (option.field == SortField.size && _sizes.isEmpty) {
      setState(() => _sortBusy = true);
      final sizes = await loadFileSizes(_library.assets.value);
      if (!mounted) return;
      _sizes = sizes;
      setState(() => _sortBusy = false);
    }
    await SortStore.save(_prefsKey, option);
    if (!mounted) return;
    setState(() => _sort = option);
  }

  /// Rebuilds [_cachedVisible] / [_cachedSections] only when an input that
  /// affects them changed. The library assets and hidden set are ValueNotifier
  /// values (new object only on real change), so identity checks are enough.
  void _rebuildDerivedIfNeeded() {
    final assets = _library.assets.value;
    final hidden = AppCollections.hidden.value;
    if (_cachedVisible != null &&
        identical(assets, _keyAssets) &&
        identical(hidden, _keyHidden) &&
        identical(_sizes, _keySizes) &&
        _keySort != null &&
        _keySort!.field == _sort.field &&
        _keySort!.dir == _sort.dir) {
      return;
    }
    _keyAssets = assets;
    _keyHidden = hidden;
    _keySizes = _sizes;
    _keySort = _sort;

    final shown = assets.where((a) => !hidden.contains(a.id)).toList();
    final visible = sortAssets(shown, _sort, sizeOf: _sizes);
    _cachedVisible = visible;
    // Day sections only matter for the grouped (date-sorted) view.
    _cachedSections = _sort.groupsByDay ? _computeSections(visible) : const [];
  }

  /// Groups the (already date-sorted) list into contiguous per-day sections.
  List<_DaySection> _computeSections(List<AssetEntity> assets) {
    final sections = <_DaySection>[];
    String? key;
    var start = 0;
    var count = 0;
    for (var i = 0; i < assets.length; i++) {
      final d = assets[i].createDateTime;
      final k =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      if (k != key) {
        if (key != null) sections.add(_DaySection(key, start, count));
        key = k;
        start = i;
        count = 0;
      }
      count++;
    }
    if (key != null) sections.add(_DaySection(key, start, count));
    return sections;
  }

  void _open(List<AssetEntity> assets, int index) {
    // No reload on return: deletions update the shared library directly, and
    // hidden/favorite changes come through their notifiers.
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ViewerPage(assets: assets, initialIndex: index),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _selection,
        AppCollections.hidden,
        GridColumns.count,
        _library.assets,
        _library.loading,
      ]),
      builder: (context, _) {
        _rebuildDerivedIfNeeded();
        final visible = _cachedVisible!;
        // Only block the whole page while the very first scan has nothing yet.
        final loading =
            (_library.loading.value && _library.assets.value.isEmpty) ||
                _sortBusy;
        return Scaffold(
          appBar: _selection.active
              ? selectionAppBar(
                  selection: _selection,
                  all: visible,
                )
              : AppBar(
                  title: const Text('日期'),
                  actions: [
                    SortMenuButton(current: _sort, onSelected: _changeSort),
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'hidden') {
                          // Unhiding updates AppCollections.hidden, which this
                          // AnimatedBuilder listens to — no rescan needed.
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const HiddenPage(),
                          ));
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
          body: loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _library.refresh,
                  child: visible.isEmpty
                      ? ListView(
                          controller: _scroll,
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(
                              height: 400,
                              child: Center(child: Text('沒有找到照片')),
                            ),
                          ],
                        )
                      : PinchColumns(
                          child: _sort.groupsByDay
                              ? _GroupedByDay(
                                  assets: visible,
                                  sections: _cachedSections,
                                  columns: GridColumns.count.value,
                                  selection: _selection,
                                  onOpen: _open,
                                  controller: _scroll,
                                )
                              : _FlatGrid(
                                  assets: visible,
                                  columns: GridColumns.count.value,
                                  selection: _selection,
                                  onOpen: _open,
                                  controller: _scroll,
                                ),
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
    required this.controller,
  });

  final List<AssetEntity> assets;
  final int columns;
  final SelectionController selection;
  final void Function(List<AssetEntity>, int) onOpen;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
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

/// A contiguous run of photos that share one calendar day. [start] is the
/// index of the first photo into the visible list, [count] how many follow.
class _DaySection {
  const _DaySection(this.dayKey, this.start, this.count);
  final String dayKey;
  final int start;
  final int count;
}

class _GroupedByDay extends StatelessWidget {
  const _GroupedByDay({
    required this.assets,
    required this.sections,
    required this.columns,
    required this.selection,
    required this.onOpen,
    required this.controller,
  });

  final List<AssetEntity> assets;
  final List<_DaySection> sections;
  final int columns;
  final SelectionController selection;
  final void Function(List<AssetEntity>, int) onOpen;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    // Sections are precomputed (and cached) by the parent; here we only lay
    // them out. Each day's grid still builds its thumbnails lazily.
    final slivers = <Widget>[];
    for (final section in sections) {
      final start = section.start;
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
            child: Text(
              section.dayKey,
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
              childCount: section.count,
            ),
          ),
        ),
      );
    }
    return CustomScrollView(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: slivers,
    );
  }
}
