import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'wallpaper_crop_page.dart';
import 'wallpaper_playlist.dart';

/// Editor for one playlist item's "window sequence": an ordered list of
/// framings ([CropWindow]) of a single original image. The whole sequence is
/// still one entry in the playlist; on the home screen the live wallpaper walks
/// through the windows in order (swipe or timed) before moving to the next
/// item.
///
/// Here the user can add, edit (via the crop picker), reorder and delete
/// windows. At least one window is always kept.
class WallpaperSequencePage extends StatelessWidget {
  const WallpaperSequencePage({
    super.key,
    required this.asset,
    required this.target,
  });

  final AssetEntity asset;
  final WallpaperTarget target;

  Future<void> _addWindow(BuildContext context) async {
    final window = await Navigator.of(context).push<CropWindow>(
      MaterialPageRoute<CropWindow>(
        builder: (_) => WallpaperCropPage(asset: asset, pickWindow: true),
      ),
    );
    if (window != null) {
      await WallpaperPlaylist.addWindow(target, asset.id, window);
    }
  }

  Future<void> _editWindow(
      BuildContext context, int index, CropWindow current) async {
    final window = await Navigator.of(context).push<CropWindow>(
      MaterialPageRoute<CropWindow>(
        builder: (_) => WallpaperCropPage(
          asset: asset,
          pickWindow: true,
          initialZoom: current.zoom,
          initialFocusX: current.focusX,
          initialFocusY: current.focusY,
        ),
      ),
    );
    if (window != null) {
      await WallpaperPlaylist.updateWindow(target, asset.id, index, window);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('視窗序列（${target.label}）'),
      ),
      body: ValueListenableBuilder<List<WallpaperItem>>(
        valueListenable: WallpaperPlaylist.listFor(target),
        builder: (context, list, _) {
          final item = list.firstWhere(
            (e) => e.id == asset.id,
            orElse: () => WallpaperItem(id: asset.id, mime: '', animated: false),
          );
          final windows = item.windows;
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '這張圖片可以切成多個「視窗」，播放時會依序顯示（右滑前進、左滑返回；也會依設定的秒數自動換）。'
                  '整個序列只占輪播清單的一個項目。長按右側把手可拖曳調整順序。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: windows.length,
                  onReorder: (o, n) => WallpaperPlaylist.reorderWindows(
                      target, asset.id, o, n),
                  itemBuilder: (context, i) {
                    final w = windows[i];
                    return _WindowTile(
                      key: ValueKey('${asset.id}_win_$i'),
                      asset: asset,
                      index: i,
                      window: w,
                      canDelete: windows.length > 1,
                      onEdit: () => _editWindow(context, i, w),
                      onDelete: () => WallpaperPlaylist.removeWindow(
                          target, asset.id, i),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addWindow(context),
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('新增視窗'),
      ),
    );
  }
}

class _WindowTile extends StatelessWidget {
  const _WindowTile({
    super.key,
    required this.asset,
    required this.index,
    required this.window,
    required this.canDelete,
    required this.onEdit,
    required this.onDelete,
  });

  final AssetEntity asset;
  final int index;
  final CropWindow window;
  final bool canDelete;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // Approximate preview: the whole image when the window is the default
    // (fit/centered), otherwise a cover crop aligned at the window's focus.
    final alignment = Alignment(
      (window.focusX * 2 - 1).clamp(-1.0, 1.0),
      (window.focusY * 2 - 1).clamp(-1.0, 1.0),
    );
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      onTap: onEdit,
      leading: SizedBox(
        width: 44,
        height: 72,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: ColoredBox(
            color: Colors.black,
            child: AssetEntityImage(
              asset,
              isOriginal: false,
              thumbnailSize: ThumbnailSize.square(240),
              thumbnailFormat: ThumbnailFormat.jpeg,
              fit: window.isDefault ? BoxFit.contain : BoxFit.cover,
              alignment: window.isDefault ? Alignment.center : alignment,
              filterQuality: FilterQuality.low,
              errorBuilder: (context, error, stack) => const Icon(
                Icons.broken_image_outlined,
                size: 20,
                color: Colors.white54,
              ),
            ),
          ),
        ),
      ),
      title: Text('視窗 ${index + 1}'),
      subtitle: Text(
        window.isDefault ? '完整置中' : '自訂裁切',
        style: TextStyle(
          fontSize: 12,
          color: window.isDefault ? null : Colors.green,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.crop),
            tooltip: '編輯視窗',
            visualDensity: VisualDensity.compact,
            onPressed: onEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: canDelete ? '刪除視窗' : '至少要保留一個視窗',
            visualDensity: VisualDensity.compact,
            onPressed: canDelete ? onDelete : null,
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
    );
  }
}
