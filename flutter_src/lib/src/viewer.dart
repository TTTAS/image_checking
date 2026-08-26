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

  void _showInfo() {
    final asset = _current;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return FutureBuilder<Map<String, String>>(
          future: _collectInfo(asset),
          builder: (ctx, snap) {
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final info = snap.data!;
            return SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      '詳細資訊',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                  ),
                  for (final e in info.entries)
                    ListTile(
                      dense: true,
                      title: Text(e.key,
                          style: const TextStyle(fontSize: 12)),
                      subtitle: Text(e.value,
                          style: const TextStyle(fontSize: 15)),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<Map<String, String>> _collectInfo(AssetEntity a) async {
    final file = await a.file;
    final bytes = file != null ? await file.length() : 0;
    final lat = a.latitude ?? 0;
    final lng = a.longitude ?? 0;
    return {
      '檔名': a.title ?? '(未知)',
      '尺寸': '${a.width} × ${a.height}',
      '檔案大小': _formatBytes(bytes),
      '拍攝時間': _formatDate(a.createDateTime),
      '修改時間': _formatDate(a.modifiedDateTime),
      '類型': a.mimeType ?? '(未知)',
      if (lat != 0 || lng != 0)
        '位置': '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
      if ((a.relativePath ?? '').isNotEmpty) '路徑': a.relativePath!,
    };
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
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
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '詳細資訊',
            onPressed: _showInfo,
          ),
        ],
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
