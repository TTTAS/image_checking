import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'collections.dart';
import 'photo_actions.dart';

/// Full-screen viewer: swipe between photos, pinch-zoom, and act on a single
/// photo (favorite / edit / share / hide / delete).
class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.assets,
    required this.initialIndex,
  });

  final List<AssetEntity> assets;
  final int initialIndex;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final PageController _controller;
  late List<AssetEntity> _assets;
  late int _index;

  @override
  void initState() {
    super.initState();
    _assets = List<AssetEntity>.from(widget.assets);
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  AssetEntity get _current => _assets[_index];

  Future<void> _delete() async {
    final deleted = await PhotoActions.delete([_current]);
    if (deleted.isEmpty || !mounted) return;
    setState(() {
      _assets.removeAt(_index);
      if (_index >= _assets.length) _index = _assets.length - 1;
    });
    if (_assets.isEmpty && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_assets.isEmpty) return const SizedBox.shrink();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _current.title ?? '${_index + 1} / ${_assets.length}',
          style: const TextStyle(fontSize: 15),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: _assets.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          return InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: AssetEntityImage(
                _assets[i],
                isOriginal: true,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white54,
                  size: 48,
                ),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: Listenable.merge([
          AppCollections.favorites,
          AppCollections.hidden,
        ]),
        builder: (context, _) {
          final id = _current.id;
          final fav = AppCollections.isFavorite(id);
          final hidden = AppCollections.isHidden(id);
          return BottomAppBar(
            color: Colors.black,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _action(
                  icon: fav ? Icons.favorite : Icons.favorite_border,
                  color: fav ? Colors.redAccent : Colors.white,
                  label: '最愛',
                  onTap: () => AppCollections.toggleFavorite(id),
                ),
                _action(
                  icon: Icons.tune,
                  label: '編輯',
                  onTap: () => PhotoActions.openEditor(context, _current),
                ),
                _action(
                  icon: Icons.share_outlined,
                  label: '分享',
                  onTap: () => PhotoActions.share([_current]),
                ),
                _action(
                  icon: hidden ? Icons.visibility : Icons.visibility_off_outlined,
                  label: hidden ? '取消隱藏' : '隱藏',
                  onTap: () => AppCollections.toggleHidden(id),
                ),
                _action(
                  icon: Icons.delete_outline,
                  label: '刪除',
                  onTap: _delete,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
