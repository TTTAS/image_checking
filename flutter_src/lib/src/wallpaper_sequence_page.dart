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
/// The top panel is a phone-screen-shaped viewport that shows the selected
/// window exactly as the wallpaper would; dragging pans the image inside it
/// (the picture slides under a fixed frame) and updates that window's crop.
/// Below it a thin strip shows the whole image with every window's crop outline
/// (tap to select which window the viewport edits), then the reorderable list.
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
              _PreviewPanel(
                asset: asset,
                windows: windows,
                imgAspect: imgAspect,
                screenAspect: screenAspect,
                onWindowMoved: (index, window) => WallpaperPlaylist.updateWindow(
                    target, asset.id, index, window),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 2, 16, 6),
                child: Text(
                  '上方視窗＝主畫面實際看到的畫面，手指在裡面滑動就是移動這張圖。'
                  '下方細條可點選要調哪個視窗；主畫面左滑／右滑依序切換視窗。',
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

/// Visible half-extent (normalized 0..1) of a window in each axis. Mirrors the
/// crop transform math (zoom is a cover-space multiplier; <=0 means fit).
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

double _clampFocus(double v, double half) {
  if (half >= 0.5) return 0.5;
  return v.clamp(half, 1 - half);
}

class _PreviewPanel extends StatefulWidget {
  const _PreviewPanel({
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
  State<_PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<_PreviewPanel> {
  int _selected = 0;
  bool _dragging = false;
  double _liveX = 0.5;
  double _liveY = 0.5;

  int get _sel => _selected.clamp(0, widget.windows.length - 1);

  CropWindow get _selWindow => widget.windows[_sel];

  double get _fx => _dragging ? _liveX : _selWindow.focusX;
  double get _fy => _dragging ? _liveY : _selWindow.focusY;

  /// Displayed image size inside a [vw]x[vh] viewport for the current window.
  ({double w, double h}) _disp(double vw, double vh) {
    final a = widget.imgAspect;
    final cover = (vw / a > vh) ? vw / a : vh; // max(vw/a, vh)
    final contain = (vw / a < vh) ? vw / a : vh; // min(vw/a, vh)
    final zoom = _selWindow.zoom <= 0 ? 1.0 : _selWindow.zoom;
    final s = _selWindow.zoom <= 0 ? contain : cover * zoom;
    return (w: a * s, h: s);
  }

  void _panStart() {
    setState(() {
      _dragging = true;
      _liveX = _selWindow.focusX;
      _liveY = _selWindow.focusY;
    });
  }

  void _panBy(Offset delta, double vw, double vh) {
    final disp = _disp(vw, vh);
    final halfX = (vw / 2) / disp.w;
    final halfY = (vh / 2) / disp.h;
    setState(() {
      // Dragging the picture right reveals its left side → focus moves left.
      _liveX = _clampFocus(_liveX - delta.dx / disp.w, halfX);
      _liveY = _clampFocus(_liveY - delta.dy / disp.h, halfY);
    });
  }

  void _panEnd() {
    if (widget.windows.isNotEmpty) {
      widget.onWindowMoved(
        _sel,
        CropWindow(zoom: _selWindow.zoom, focusX: _liveX, focusY: _liveY),
      );
    }
    setState(() => _dragging = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.windows.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        // Phone-screen-shaped viewport: the picture slides inside it.
        Container(
          color: Colors.black,
          constraints: const BoxConstraints(maxHeight: 240),
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          child: AspectRatio(
            aspectRatio: widget.screenAspect,
            child: LayoutBuilder(
              builder: (context, c) {
                final vw = c.maxWidth;
                final vh = c.maxHeight;
                final disp = _disp(vw, vh);
                final left = vw / 2 - _fx * disp.w;
                final top = vh / 2 - _fy * disp.h;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => _panStart(),
                  onPanUpdate: (d) => _panBy(d.delta, vw, vh),
                  onPanEnd: (_) => _panEnd(),
                  onPanCancel: () => setState(() => _dragging = false),
                  child: ClipRect(
                    child: Stack(
                      children: [
                        Positioned(
                          left: left,
                          top: top,
                          width: disp.w,
                          height: disp.h,
                          child: AssetEntityImage(
                            widget.asset,
                            isOriginal: false,
                            thumbnailSize: ThumbnailSize.square(1080),
                            thumbnailFormat: ThumbnailFormat.jpeg,
                            fit: BoxFit.fill,
                            errorBuilder: (context, error, stack) =>
                                const ColoredBox(color: Colors.black),
                          ),
                        ),
                        if (_dragging)
                          const Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(painter: _ViewportGuides()),
                            ),
                          ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: WallpaperSequencePage.colorFor(_sel),
                                  width: 2.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        // Whole-image strip with every window outline; tap to pick which one
        // the viewport edits.
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: LayoutBuilder(
            builder: (context, c) {
              final stripH = (c.maxWidth / widget.imgAspect).clamp(40.0, 90.0);
              return SizedBox(
                width: c.maxWidth,
                height: stripH,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    final nx = (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0);
                    final ny = (d.localPosition.dy / stripH).clamp(0.0, 1.0);
                    setState(() => _selected = _nearestWindow(nx, ny));
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        AssetEntityImage(
                          widget.asset,
                          isOriginal: false,
                          thumbnailSize: ThumbnailSize.square(480),
                          thumbnailFormat: ThumbnailFormat.jpeg,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stack) =>
                              const ColoredBox(color: Colors.black),
                        ),
                        CustomPaint(
                          painter: _MiniOverviewPainter(
                            windows: widget.windows,
                            imgAspect: widget.imgAspect,
                            screenAspect: widget.screenAspect,
                            selected: _sel,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '正在調整：視窗 ${_sel + 1} / ${widget.windows.length}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  int _nearestWindow(double nx, double ny) {
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < widget.windows.length; i++) {
      final w = widget.windows[i];
      final dx = (w.focusX - nx);
      final dy = (w.focusY - ny) * 0.5;
      final d = dx * dx + dy * dy;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }
}

class _ViewportGuides extends CustomPainter {
  const _ViewportGuides();

  @override
  void paint(Canvas canvas, Size size) {
    final thirds = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i <= 2; i++) {
      final x = size.width * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), thirds);
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), thirds);
    }
    final center = Paint()
      ..color = const Color(0xFFFFCA28).withValues(alpha: 0.7)
      ..strokeWidth = 1.4;
    canvas.drawLine(
        Offset(size.width / 2, 0), Offset(size.width / 2, size.height), center);
    canvas.drawLine(Offset(0, size.height / 2),
        Offset(size.width, size.height / 2), center);
  }

  @override
  bool shouldRepaint(covariant _ViewportGuides oldDelegate) => false;
}

class _MiniOverviewPainter extends CustomPainter {
  _MiniOverviewPainter({
    required this.windows,
    required this.imgAspect,
    required this.screenAspect,
    required this.selected,
  });

  final List<CropWindow> windows;
  final double imgAspect;
  final double screenAspect;
  final int selected;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < windows.length; i++) {
      final color = WallpaperSequencePage.colorFor(i);
      final active = i == selected;
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
          ..strokeWidth = active ? 3 : 1.6
          ..color = active ? color : color.withValues(alpha: 0.7),
      );
      if (active) {
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.fill
            ..color = color.withValues(alpha: 0.18),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MiniOverviewPainter old) =>
      old.windows != windows ||
      old.selected != selected ||
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
            tooltip: '放大編輯（可縮放）',
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
