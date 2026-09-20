import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'wallpaper_crop_page.dart';
import 'wallpaper_playlist.dart';

/// Editor for one playlist item's "window sequence": an ordered list of
/// framings ([CropWindow]) of a single original image. The whole sequence is
/// still one entry in the playlist; on the home screen the live wallpaper steps
/// through the windows by left/right swipe (it does NOT auto-advance windows).
///
/// The top panel shows the whole image with every window's crop outline drawn
/// on it (numbered, colour-matched to the list). You can **drag a window's box
/// directly on that image** to fine-tune where it crops; releasing saves it.
/// Below, windows can be added, auto-sliced, edited, reordered and deleted.
/// At least one window is always kept.
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
    final visible = screenAspect / imgAspect;
    if (visible <= 0 || visible >= 0.999) {
      return [CropWindow(zoom: 1.0)];
    }
    final n = (1 / visible).ceil().clamp(2, 12);
    final windows = <CropWindow>[];
    for (var i = 0; i < n; i++) {
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
                onWindowMoved: (index, window) => WallpaperPlaylist.updateWindow(
                    target, asset.id, index, window),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '每個「視窗」是這張圖的一塊顯示範圍，主畫面左滑／右滑依序切換（不會自動換）。'
                  '在上圖用手指拖曳任一顏色框，即可微調該視窗裁切的位置（放開即存，拖曳時顯示對齊線）；'
                  '點下方清單可放大編輯。寬圖想整張看完，按右上角「自動切片」。',
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

/// Visible half-extent (normalized 0..1) of a window in each axis, and the
/// rectangle it shows. Mirrors the crop page's transform math.
({double halfW, double halfH}) _visibleHalf(
    CropWindow w, double imgAspect, double screenAspect) {
  const bw = 1.0;
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
  return (halfW: bw / (2 * zoom * cw), halfH: bh / (2 * zoom * ch));
}

Rect windowRect(CropWindow w, double imgAspect, double screenAspect) {
  final h = _visibleHalf(w, imgAspect, screenAspect);
  double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  return Rect.fromLTRB(
    clamp01(w.focusX - h.halfW),
    clamp01(w.focusY - h.halfH),
    clamp01(w.focusX + h.halfW),
    clamp01(w.focusY + h.halfH),
  );
}

class _Overview extends StatefulWidget {
  const _Overview({
    required this.asset,
    required this.windows,
    required this.imgAspect,
    required this.screenAspect,
    required this.onWindowMoved,
  });

  final AssetEntity asset;
  final List<CropWindow> windows;
  final double imgAspect;
  final double screenAspect;
  final void Function(int index, CropWindow window) onWindowMoved;

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  int _grabbed = -1;
  double _liveX = 0.5;
  double _liveY = 0.5;

  /// Constrain focus so the window stays fully on the image (no black edges).
  double _clampFocus(double v, double half) {
    if (half >= 0.5) return 0.5;
    return v.clamp(half, 1 - half);
  }

  int _nearestWindow(double nx, double ny) {
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < widget.windows.length; i++) {
      final w = widget.windows[i];
      // Weight X more than Y (strips usually differ horizontally).
      final dx = (w.focusX - nx) * 1.0;
      final dy = (w.focusY - ny) * 0.5;
      final d = dx * dx + dy * dy;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  void _start(double nx, double ny) {
    if (widget.windows.isEmpty) return;
    final i = _nearestWindow(nx, ny);
    final w = widget.windows[i];
    final h = _visibleHalf(w, widget.imgAspect, widget.screenAspect);
    setState(() {
      _grabbed = i;
      _liveX = _clampFocus(nx, h.halfW);
      _liveY = _clampFocus(ny, h.halfH);
    });
  }

  void _move(double nx, double ny) {
    if (_grabbed < 0) return;
    final w = widget.windows[_grabbed];
    final h = _visibleHalf(w, widget.imgAspect, widget.screenAspect);
    setState(() {
      _liveX = _clampFocus(nx, h.halfW);
      _liveY = _clampFocus(ny, h.halfH);
    });
  }

  void _end() {
    if (_grabbed >= 0 && _grabbed < widget.windows.length) {
      final w = widget.windows[_grabbed];
      widget.onWindowMoved(
        _grabbed,
        CropWindow(zoom: w.zoom, focusX: _liveX, focusY: _liveY),
      );
    }
    setState(() => _grabbed = -1);
  }

  @override
  Widget build(BuildContext context) {
    // While dragging, show the grabbed window at its live position.
    final effective = List<CropWindow>.from(widget.windows);
    if (_grabbed >= 0 && _grabbed < effective.length) {
      effective[_grabbed] = CropWindow(
        zoom: effective[_grabbed].zoom,
        focusX: _liveX,
        focusY: _liveY,
      );
    }
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
            final h = constraints.maxHeight;
            double nx(double dx) => (w > 0 ? dx / w : 0.5).clamp(0.0, 1.0);
            double ny(double dy) => (h > 0 ? dy / h : 0.5).clamp(0.0, 1.0);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (d) =>
                  _start(nx(d.localPosition.dx), ny(d.localPosition.dy)),
              onPanUpdate: (d) =>
                  _move(nx(d.localPosition.dx), ny(d.localPosition.dy)),
              onPanEnd: (_) => _end(),
              onPanCancel: _end,
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
                      windows: effective,
                      imgAspect: widget.imgAspect,
                      screenAspect: widget.screenAspect,
                      grabbed: _grabbed,
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
    required this.grabbed,
  });

  final List<CropWindow> windows;
  final double imgAspect;
  final double screenAspect;
  final int grabbed;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < windows.length; i++) {
      final color = WallpaperSequencePage.colorFor(i);
      final active = i == grabbed;
      final dim = grabbed >= 0 && !active;
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
          ..strokeWidth = active ? 3.5 : 2.5
          ..color = dim ? color.withValues(alpha: 0.35) : color,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: active ? 0.22 : (dim ? 0.05 : 0.12)),
      );
      _drawBadge(canvas, '${i + 1}', rect.left + 2, rect.top + 2, color);
    }

    if (grabbed >= 0 && grabbed < windows.length) {
      _drawGuides(canvas, size);
      final w = windows[grabbed];
      _drawText(
        canvas,
        '左 ${(w.focusX * 100).round()}%',
        6,
        size.height - 22,
        color: Colors.white,
        fontSize: 12,
        background: Colors.black.withValues(alpha: 0.5),
      );
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
    canvas.drawLine(
        Offset(size.width / 2, 0), Offset(size.width / 2, size.height), center);
    canvas.drawLine(Offset(0, size.height / 2),
        Offset(size.width, size.height / 2), center);
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
      old.grabbed != grabbed;
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
