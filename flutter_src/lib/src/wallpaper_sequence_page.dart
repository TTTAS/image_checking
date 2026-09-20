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
/// drawn on it (numbered in order); drag it left/right to scrub, which reveals
/// alignment guides and a percentage ruler. Below it the windows can be added,
/// auto-sliced, edited (via the crop picker), reordered and deleted. At least
/// one window is always kept.
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

  /// Full-height, screen-width strips tiled left→right to cover the whole image
  /// (centred), so swiping pans across the entire wide picture. zoom = 1.0 is
  /// exactly "fill height, crop width" in the crop transform space.
  static List<CropWindow> autoSliceWindows(
      double imgAspect, double screenAspect) {
    // Fraction of the image width one full-height strip shows.
    final visible = screenAspect / imgAspect;
    if (visible <= 0 || visible >= 0.999) {
      return [CropWindow(zoom: 1.0)];
    }
    final n = (1 / visible).ceil().clamp(2, 12);
    final windows = <CropWindow>[];
    for (var i = 0; i < n; i++) {
      // Spread focus so strip 0 is flush-left and strip n-1 flush-right.
      final fx = visible / 2 + i * (1 - visible) / (n - 1);
      windows.add(CropWindow(zoom: 1.0, focusX: fx, focusY: 0.5));
    }
    return windows;
  }

  Future<void> _autoSlice(
      BuildContext context, double imgAspect, double screenAspect) async {
    final messenger = ScaffoldMessenger.of(context);
    final windows = autoSliceWindows(imgAspect, screenAspect);
    if (windows.length < 2) {
      messenger.showSnackBar(const SnackBar(
        content: Text('這張圖沒有比螢幕寬，用不到左右切片。'),
      ));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自動切片'),
        content: Text(
          '會把這張圖切成 ${windows.length} 個「滿高、螢幕寬」的視窗，'
          '由左到右覆蓋整張圖，取代目前的視窗設定。要繼續嗎？',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('切片')),
        ],
      ),
    );
    if (ok == true) {
      await WallpaperPlaylist.setWindows(target, asset.id, windows);
      messenger.showSnackBar(
          SnackBar(content: Text('已切成 ${windows.length} 個視窗，左右滑動看完整張圖')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenAspect =
        mq.size.height > 0 ? mq.size.width / mq.size.height : 0.5;
    final iw = asset.width.toDouble();
    final ih = asset.height.toDouble();
    final imgAspect = (iw > 0 && ih > 0) ? iw / ih : 1.0;

    return Scaffold(
      appBar: AppBar(
        title: Text('視窗序列（${target.label}）'),
        actions: [
          IconButton(
            icon: const Icon(Icons.view_column_outlined),
            tooltip: '自動切片（寬圖左右可滑）',
            onPressed: () => _autoSlice(context, imgAspect, screenAspect),
          ),
        ],
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
                  '每個「視窗」是這張圖的一塊顯示範圍，主畫面左滑／右滑依序切換（不會自動換）。'
                  '上圖用對應顏色標出各視窗；用手指左右滑動上圖可檢視，會顯示輔助線與刻度。'
                  '寬圖想整張看完，按右上角「自動切片」。',
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

class _Overview extends StatefulWidget {
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
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  bool _dragging = false;
  double _dragX = 0.5; // normalized 0..1

  void _setDrag(double x) {
    setState(() {
      _dragging = true;
      _dragX = x.clamp(0.0, 1.0);
    });
  }

  void _endDrag() {
    setState(() => _dragging = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      constraints: const BoxConstraints(maxHeight: 260),
      padding: const EdgeInsets.all(8),
      alignment: Alignment.center,
      child: AspectRatio(
        aspectRatio: widget.imgAspect,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (d) =>
                  _setDrag(w > 0 ? d.localPosition.dx / w : 0.5),
              onHorizontalDragUpdate: (d) =>
                  _setDrag(w > 0 ? d.localPosition.dx / w : 0.5),
              onHorizontalDragEnd: (_) => _endDrag(),
              onHorizontalDragCancel: _endDrag,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AssetEntityImage(
                    widget.asset,
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
                      windows: widget.windows,
                      imgAspect: widget.imgAspect,
                      screenAspect: widget.screenAspect,
                      dragging: _dragging,
                      dragX: _dragX,
                    ),
                  ),
                ],
              ),
            );
          },
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
    required this.dragging,
    required this.dragX,
  });

  final List<CropWindow> windows;
  final double imgAspect;
  final double screenAspect;
  final bool dragging;
  final double dragX;

  @override
  void paint(Canvas canvas, Size size) {
    // Crop rectangles, one per window.
    for (var i = 0; i < windows.length; i++) {
      final color = WallpaperSequencePage.colorFor(i);
      final r = windowRect(windows[i], imgAspect, screenAspect);
      final rect = Rect.fromLTRB(
        r.left * size.width,
        r.top * size.height,
        r.right * size.width,
        r.bottom * size.height,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = color,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: 0.12),
      );
      _drawBadge(canvas, '${i + 1}', rect.left + 2, rect.top + 2, color);
    }

    if (dragging) {
      _drawGuides(canvas, size);
      _drawRuler(canvas, size);
      _drawPlayhead(canvas, size);
    }
  }

  void _drawGuides(Canvas canvas, Size size) {
    final thirds = Paint()
      ..color = Colors.white.withValues(alpha: 0.30)
      ..strokeWidth = 1;
    for (var i = 1; i <= 2; i++) {
      final x = size.width * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), thirds);
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), thirds);
    }
    final center = Paint()
      ..color = const Color(0xFFFFCA28).withValues(alpha: 0.6)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(0, size.height / 2),
        Offset(size.width, size.height / 2), center);
  }

  /// Percentage scale along the top edge.
  void _drawRuler(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, 16),
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    final tick = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    for (var p = 0; p <= 100; p += 10) {
      final x = size.width * p / 100;
      final major = p % 25 == 0;
      canvas.drawLine(Offset(x, 0), Offset(x, major ? 10 : 6), tick);
      if (major) {
        _drawText(canvas, '$p', x + 2, 3,
            color: Colors.white, fontSize: 9);
      }
    }
  }

  void _drawPlayhead(Canvas canvas, Size size) {
    final x = dragX * size.width;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.6,
    );
    final pct = (dragX * 100).round();
    _drawText(
      canvas,
      '$pct%',
      (x + 4).clamp(0.0, size.width - 34),
      size.height - 20,
      color: Colors.white,
      fontSize: 12,
      background: Colors.black.withValues(alpha: 0.5),
    );
  }

  void _drawBadge(
      Canvas canvas, String text, double x, double y, Color color) {
    final tp = _layout(text, Colors.white, 12, bold: true);
    final badge = Rect.fromLTWH(x, y, tp.width + 10, tp.height + 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(badge, const Radius.circular(4)),
      Paint()..color = color,
    );
    tp.paint(canvas, Offset(badge.left + 5, badge.top + 2));
  }

  void _drawText(Canvas canvas, String text, double x, double y,
      {required Color color, required double fontSize, Color? background}) {
    final tp = _layout(text, color, fontSize);
    if (background != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x - 3, y - 2, tp.width + 6, tp.height + 4),
          const Radius.circular(3),
        ),
        Paint()..color = background,
      );
    }
    tp.paint(canvas, Offset(x, y));
  }

  TextPainter _layout(String text, Color color, double fontSize,
      {bool bold = false}) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  bool shouldRepaint(covariant _WindowsPainter old) =>
      old.windows != windows ||
      old.imgAspect != imgAspect ||
      old.screenAspect != screenAspect ||
      old.dragging != dragging ||
      old.dragX != dragX;
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
