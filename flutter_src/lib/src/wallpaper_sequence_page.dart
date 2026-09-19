import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'wallpaper_crop_page.dart';
import 'wallpaper_playlist.dart';

/// Editor for one playlist item's "window sequence": an ordered list of
/// framings ([CropWindow]) of a single original image. The whole sequence is
/// still one entry in the playlist; on the home screen the live wallpaper is
/// driven purely by left/right swipe, stepping through the windows in order
/// (it does NOT auto-advance on a timer).
///
/// The top panel shows the whole image once with every window's crop outline
/// drawn on it (numbered in order), so the sequence is legible at a glance.
/// Below it the windows can be added, edited (via the crop picker), reordered
/// and deleted. At least one window is always kept.
class WallpaperSequencePage extends StatelessWidget {
  const WallpaperSequencePage({
    super.key,
    required this.asset,
    required this.target,
  });

  final AssetEntity asset;
  final WallpaperTarget target;

  /// Distinct outline colours cycled per window.
  static const List<Color> _palette = [
    Color(0xFF42A5F5), // blue
    Color(0xFFEF5350), // red
    Color(0xFF66BB6A), // green
    Color(0xFFFFCA28), // amber
    Color(0xFFAB47BC), // purple
    Color(0xFF26C6DA), // cyan
    Color(0xFFFF7043), // deep orange
  ];

  static Color colorFor(int index) => _palette[index % _palette.length];

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
    final mq = MediaQuery.of(context);
    final screenAspect = mq.size.height > 0
        ? mq.size.width / mq.size.height
        : 0.5;
    final iw = asset.width.toDouble();
    final ih = asset.height.toDouble();
    final imgAspect = (iw > 0 && ih > 0) ? iw / ih : 1.0;

    return Scaffold(
      appBar: AppBar(
        title: Text('視窗序列（${target.label}）'),
      ),
      body: ValueListenableBuilder<List<WallpaperItem>>(
        valueListenable: WallpaperPlaylist.listFor(target),
        builder: (context, list, _) {
          final item = list.firstWhere(
            (e) => e.id == asset.id,
            orElse: () =>
                WallpaperItem(id: asset.id, mime: '', animated: false),
          );
          final windows = item.windows;
          return Column(
            children: [
              _Overview(
                asset: asset,
                windows: windows,
                imgAspect: imgAspect,
                screenAspect: screenAspect,
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '每個「視窗」是這張圖的一塊顯示範圍，播放時在主畫面用左滑／右滑依序切換'
                  '（不會自動換）。上圖用對應顏色標出每個視窗的裁切框；長按右側把手可調整順序。',
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
                      color: colorFor(i),
                      canDelete: windows.length > 1,
                      onEdit: () => _editWindow(context, i, w),
                      onDelete: () =>
                          WallpaperPlaylist.removeWindow(target, asset.id, i),
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

/// Normalized (0..1) rectangle of the original image that a window shows, given
/// the wallpaper screen aspect. Mirrors the crop page's transform math so the
/// outline matches what will actually be displayed.
Rect windowRect(CropWindow w, double imgAspect, double screenAspect) {
  const bw = 1.0; // nominal box; only ratios matter.
  final bh = bw / screenAspect;
  double cw, ch;
  if (imgAspect > screenAspect) {
    ch = bh;
    cw = bh * imgAspect;
  } else {
    cw = bw;
    ch = bw / imgAspect;
  }
  final fitScale = (bw / cw < bh / ch) ? bw / cw : bh / ch;
  final zoom = w.zoom <= 0 ? fitScale : w.zoom;
  final halfW = bw / (2 * zoom * cw);
  final halfH = bh / (2 * zoom * ch);
  double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  return Rect.fromLTRB(
    clamp01(w.focusX - halfW),
    clamp01(w.focusY - halfH),
    clamp01(w.focusX + halfW),
    clamp01(w.focusY + halfH),
  );
}

class _Overview extends StatelessWidget {
  const _Overview({
    required this.asset,
    required this.windows,
    required this.imgAspect,
    required this.screenAspect,
  });

  final AssetEntity asset;
  final List<CropWindow> windows;
  final double imgAspect;
  final double screenAspect;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      constraints: const BoxConstraints(maxHeight: 260),
      padding: const EdgeInsets.all(8),
      alignment: Alignment.center,
      child: AspectRatio(
        aspectRatio: imgAspect,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AssetEntityImage(
              asset,
              isOriginal: false,
              thumbnailSize: ThumbnailSize.square(720),
              thumbnailFormat: ThumbnailFormat.jpeg,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => const ColoredBox(
                color: Colors.black,
                child: Icon(Icons.broken_image_outlined,
                    color: Colors.white54, size: 40),
              ),
            ),
            CustomPaint(
              painter: _WindowsPainter(
                windows: windows,
                imgAspect: imgAspect,
                screenAspect: screenAspect,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowsPainter extends CustomPainter {
  _WindowsPainter({
    required this.windows,
    required this.imgAspect,
    required this.screenAspect,
  });

  final List<CropWindow> windows;
  final double imgAspect;
  final double screenAspect;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < windows.length; i++) {
      final color = WallpaperSequencePage.colorFor(i);
      final r = windowRect(windows[i], imgAspect, screenAspect);
      final rect = Rect.fromLTRB(
        r.left * size.width,
        r.top * size.height,
        r.right * size.width,
        r.bottom * size.height,
      );
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = color;
      canvas.drawRect(rect, stroke);
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: 0.12),
      );

      // Numbered badge at the rectangle's top-left corner.
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final badge = Rect.fromLTWH(
        rect.left + 2,
        rect.top + 2,
        tp.width + 10,
        tp.height + 4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(badge, const Radius.circular(4)),
        Paint()..color = color,
      );
      tp.paint(canvas, Offset(badge.left + 5, badge.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant _WindowsPainter old) =>
      old.windows != windows ||
      old.imgAspect != imgAspect ||
      old.screenAspect != screenAspect;
}

class _WindowTile extends StatelessWidget {
  const _WindowTile({
    super.key,
    required this.asset,
    required this.index,
    required this.window,
    required this.color,
    required this.canDelete,
    required this.onEdit,
    required this.onDelete,
  });

  final AssetEntity asset;
  final int index;
  final CropWindow window;
  final Color color;
  final bool canDelete;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
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
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 2),
              borderRadius: BorderRadius.circular(6),
            ),
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
