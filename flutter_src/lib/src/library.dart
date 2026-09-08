import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import 'media.dart';

/// One shared, cached scan of the whole media library.
///
/// The date tab and the favorites tab both read from this instead of each
/// running their own full scan. It loads once (paged, newest first), then
/// updates incrementally: deletions just drop ids ([removeIds]) and a fresh
/// scan only runs when a caller asks for it ([refresh], e.g. pull-to-refresh).
/// Hidden / favorite changes are handled separately by [AppCollections]'s own
/// notifiers, so they never need a rescan here.
class PhotoLibrary {
  PhotoLibrary._();
  static final PhotoLibrary instance = PhotoLibrary._();

  /// Assets per page. Small so the first page paints fast; the rest stream in.
  static const _pageSize = 60;

  /// The cached assets, newest first. Widgets listen to this.
  final ValueNotifier<List<AssetEntity>> assets =
      ValueNotifier<List<AssetEntity>>([]);

  /// True until the very first scan has produced something to show.
  final ValueNotifier<bool> loading = ValueNotifier<bool>(true);

  bool _started = false;
  int _loadToken = 0;

  // ---- Auto-sync with the system gallery --------------------------------

  /// Coalesces bursts of system change events into a single rescan.
  Timer? _debounce;
  bool _observing = false;

  /// When we last mutated the cache ourselves (e.g. an in-app delete). System
  /// change events fired right after are our own echo — skip them so deleting
  /// in the app doesn't trigger a full rescan on top of the instant
  /// [removeIds] update.
  DateTime _selfEditAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Loads the library the first time it's needed. Safe to call from every
  /// build — only the first call triggers a scan; later calls are no-ops.
  Future<void> ensureLoaded() async {
    if (_started) return;
    _started = true;
    await refresh();
    _startObserving();
  }

  /// Subscribes to OS media-store changes so photos added/removed by other
  /// apps (camera, another gallery, our own editor saving a new file) show up
  /// without a manual pull-to-refresh.
  void _startObserving() {
    if (_observing) return;
    _observing = true;
    PhotoManager.addChangeCallback(_onSystemChange);
    PhotoManager.startChangeNotify();
  }

  void _onSystemChange(MethodCall _) {
    // Our own in-app edit already updated the cache; ignore its echo.
    if (DateTime.now().difference(_selfEditAt) < const Duration(seconds: 3)) {
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), refresh);
  }

  /// Re-scans the library (paged, newest first). The previous list stays in
  /// [assets] until the first page of the new scan arrives, so there's no
  /// blank flash when refreshing.
  Future<void> refresh() async {
    final token = ++_loadToken;
    final paths = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: kMediaType,
      // Ask the OS to sort newest-first so page 0 is the recent photos shown
      // at the top, instead of them only surfacing once everything loads.
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (token != _loadToken) return;
    if (paths.isEmpty) {
      assets.value = [];
      loading.value = false;
      return;
    }

    final all = paths.first;
    final loaded = <AssetEntity>[];
    for (var page = 0;; page++) {
      final batch = await all.getAssetListPaged(page: page, size: _pageSize);
      if (token != _loadToken) return;
      if (batch.isEmpty) break;
      loaded.addAll(batch);
      assets.value = List<AssetEntity>.of(loaded);
      loading.value = false;
      if (batch.length < _pageSize) break;
    }
    // Empty library, or the last page cleared everything.
    assets.value = loaded;
    loading.value = false;
  }

  /// Drops deleted ids from the cache without a rescan, so returning from the
  /// viewer or a multi-select delete updates instantly.
  void removeIds(Iterable<String> ids) {
    final gone = ids.toSet();
    if (gone.isEmpty) return;
    // Mark this as a self-edit so the OS change echo doesn't force a rescan.
    _selfEditAt = DateTime.now();
    final next = assets.value.where((a) => !gone.contains(a.id)).toList();
    if (next.length != assets.value.length) {
      assets.value = next;
    }
  }
}
