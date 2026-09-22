import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'add_to_album.dart';
import 'collections.dart';
import 'grid_columns.dart';
import 'photo_grid.dart';
import 'selection.dart';
import 'sort.dart';
import 'viewer.dart';
import 'virtual_albums.dart';
import 'widgets.dart';

/// Photos inside one virtual album ("我的相簿"). The album stores only asset
/// ids, so this resolves them to [AssetEntity]s on the fly; ids that no longer
/// exist on the device are silently dropped from the album. Hidden photos are
/// filtered out, matching the rest of the app.
class VirtualAlbumDetailPage extends StatefulWidget {
  const VirtualAlbumDetailPage({super.key, required this.albumId});

  final String albumId;

  @override
  State<VirtualAlbumDetailPage> createState() => _VirtualAlbumDetailPageState();
}

class _VirtualAlbumDetailPageState extends State<VirtualAlbumDetailPage> {
  static const _prefsKey = 'virtual_album_photos';
  static const _fallback = SortOption(SortField.date, SortDir.desc);

  final SelectionController _selection = SelectionController();
  List<AssetEntity> _all = [];
  List<String> _loadedIds = const [];
  Map<String, int> _sizes = {};
  SortOption _sort = _fallback;
  bool _loading = true;
  bool _pickingCover = false;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    VirtualAlbums.albums.addListener(_onAlbumsChanged);
    _init();
  }

  @override
  void dispose() {
    VirtualAlbums.albums.removeListener(_onAlbumsChanged);
    _selection.dispose();
    super.dispose();
  }

  /// A virtual album changed. Only re-resolve the photos when *this* album's
  /// membership changed; a rename / cover change just repaints.
  void _onAlbumsChanged() {
    final album = _album;
    if (album != null && _sameIds(album.assetIds, _loadedIds)) {
      if (mounted) setState(() {});
      return;
    }
    _reload();
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  VirtualAlbum? get _album => VirtualAlbums.byId(widget.albumId);

  Future<void> _init() async {
    _sort = await SortStore.load(_prefsKey, _fallback);
    await _reload();
  }

  Future<void> _reload() async {
    final album = _album;
    if (album == null) {
      // Album is gone (deleted). The delete flow pops the screen itself, so
      // here we just stop — popping again would remove an extra route.
      if (mounted) setState(() => _loading = false);
      return;
    }
    final token = ++_loadToken;
    setState(() => _loading = true);

    final resolved = <AssetEntity>[];
    final missing = <String>[];
    for (final id in album.assetIds) {
      final asset = await AssetEntity.fromId(id);
      if (token != _loadToken || !mounted) return;
      if (asset == null) {
        missing.add(id);
      } else {
        resolved.add(asset);
      }
    }

    // Drop ids whose files are gone (deleted outside the app).
    if (missing.isNotEmpty) {
      await VirtualAlbums.removeAssets(widget.albumId, missing);
      // removeAssets fires the listener, which re-enters _reload with a fresh
      // token; stop here and let that pass finish.
      return;
    }

    if (_sort.field == SortField.size) {
      _sizes = await loadFileSizes(resolved);
      if (token != _loadToken || !mounted) return;
    }

    setState(() {
      _all = resolved;
      _loadedIds = List<String>.from(album.assetIds);
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
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ViewerPage(assets: assets, initialIndex: index),
    ));
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _removeFromAlbum(List<AssetEntity> assets) async {
    await VirtualAlbums.removeAssets(
        widget.albumId, assets.map((a) => a.id));
    _snack('已從相簿移除 ${assets.length} 張（照片仍保留在裝置上）');
  }

  Future<void> _setCover(AssetEntity asset) async {
    await VirtualAlbums.setCover(widget.albumId, asset.id);
    if (!mounted) return;
    setState(() => _pickingCover = false);
    _snack('已設為相簿封面');
  }

  Future<void> _clearCover() async {
    await VirtualAlbums.setCover(widget.albumId, null);
    _snack('已恢復預設封面');
  }

  Future<void> _rename() async {
    final album = _album;
    if (album == null) return;
    final name =
        await promptAlbumName(context, initial: album.name, title: '重新命名相簿');
    if (name == null) return;
    await VirtualAlbums.rename(widget.albumId, name);
  }

  Future<void> _deleteAlbum() async {
    final album = _album;
    if (album == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除相簿？'),
        content: Text(
          '只會刪除「${album.name}」這個相簿分類，'
          '裡面的照片會保留在裝置上，不會被刪除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('刪除相簿'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await VirtualAlbums.remove(widget.albumId);
    if (mounted) Navigator.of(context).maybePop();
  }

  PreferredSizeWidget _appBar(List<AssetEntity> visible) {
    final album = _album;
    if (_selection.active) {
      return selectionAppBar(
        selection: _selection,
        all: visible,
        reload: _reload,
        onRemoveFromAlbum: _removeFromAlbum,
      );
    }
    if (_pickingCover) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _pickingCover = false),
        ),
        title: const Text('點一張照片設為封面'),
      );
    }
    return AppBar(
      title: Text(album?.name ?? '相簿'),
      actions: [
        SortMenuButton(current: _sort, onSelected: _changeSort),
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'rename':
                _rename();
              case 'set':
                setState(() => _pickingCover = true);
              case 'clear':
                _clearCover();
              case 'delete':
                _deleteAlbum();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'rename', child: Text('重新命名')),
            const PopupMenuItem(value: 'set', child: Text('設定封面照片')),
            if (album?.coverId != null)
              const PopupMenuItem(value: 'clear', child: Text('恢復預設封面')),
            const PopupMenuItem(value: 'delete', child: Text('刪除相簿')),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
          [_selection, AppCollections.hidden, GridColumns.count]),
      builder: (context, _) {
        final visible = _visible;
        return Scaffold(
          appBar: _appBar(visible),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : visible.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '這個相簿還沒有照片\n'
                          '在照片上多選後，點「加入相簿」即可放進來',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        if (_pickingCover)
                          Container(
                            width: double.infinity,
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            child: const Text('選一張照片作為這個相簿的封面'),
                          ),
                        Expanded(
                          child: PinchColumns(
                            child: GridView.builder(
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
                                onOpen: () => _pickingCover
                                    ? _setCover(visible[i])
                                    : _open(visible, i),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
        );
      },
    );
  }
}
