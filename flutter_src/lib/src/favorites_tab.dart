import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'app.dart';
import 'collections.dart';
import 'grid_columns.dart';
import 'library.dart';
import 'photo_grid.dart';
import 'selection.dart';
import 'viewer.dart';

/// Third tab: photos the user marked as favorite (newest first).
class FavoritesTab extends StatefulWidget {
  const FavoritesTab({super.key, required this.scrollToTop});

  final ScrollToTopSignal scrollToTop;

  @override
  State<FavoritesTab> createState() => _FavoritesTabState();
}

class _FavoritesTabState extends State<FavoritesTab> {
  final SelectionController _selection = SelectionController();
  final ScrollController _scroll = ScrollController();
  final PhotoLibrary _library = PhotoLibrary.instance;

  @override
  void initState() {
    super.initState();
    widget.scrollToTop.addListener(_scrollToTop);
    // Shares the same cached scan as the date tab; whichever loads first wins.
    _library.ensureLoaded();
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

  List<AssetEntity> get _visible {
    final list = _library.assets.value
        .where((a) =>
            AppCollections.isFavorite(a.id) && !AppCollections.isHidden(a.id))
        .toList();
    list.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    return list;
  }

  void _open(List<AssetEntity> assets, int index) {
    // No reload on return: deletions update the shared library directly, and
    // favorite/hidden changes come through their notifiers.
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ViewerPage(assets: assets, initialIndex: index),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _selection,
        AppCollections.favorites,
        AppCollections.hidden,
        GridColumns.count,
        _library.assets,
        _library.loading,
      ]),
      builder: (context, _) {
        final visible = _visible;
        // Only block the whole page while the very first scan has nothing yet.
        final loading =
            _library.loading.value && _library.assets.value.isEmpty;
        return Scaffold(
          appBar: _selection.active
              ? selectionAppBar(
                  selection: _selection,
                  all: visible,
                )
              : AppBar(title: const Text('我的最愛')),
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
                              child: Center(
                                child: Text('還沒有最愛的照片\n在照片上點愛心即可加入'),
                              ),
                            ),
                          ],
                        )
                      : PinchColumns(
                          child: GridView.builder(
                            controller: _scroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(2),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
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
                ),
        );
      },
    );
  }
}
