import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'wallpaper_crop_page.dart';
import 'wallpaper_playlist.dart';

/// Editor for one playlist item's "window sequence": an ordered list of
/// framings ([CropWindow]) of a single original image. On the home screen the
/// live wallpaper pans continuously between these windows as you swipe.
///
/// The window list is the main view. A collapsible viewport at the top can be
/// pulled out to fine-tune a window by dragging the picture inside a
/// phone-shaped frame; tapping a list row opens the full-screen editor.
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
              const Divider(height: 1),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 88),
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

double _clampFocus(double v, double half) {
  if (half >= 0.5) return 0.5;
  return v.clamp(half, 1 - half);
}

/// Collapsible "pull-out" fine-tune area. Collapsed by default so the window
/// list has room; expand it to drag the picture inside a phone-shaped frame.
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
  bool _expanded = false;
  int _selected = 0;
  bool _dragging = false;
  double _liveX = 0.5;
  double _liveY = 0.5;

  int get _sel => _selected.clamp(0, widget.windows.length - 1);
  CropWindow get _selWindow => widget.windows[_sel];
  double get _fx => _dragging ? _liveX : _selWindow.focusX;
  double get _fy => _dragging ? _liveY : _selWindow.focusY;

  ({double w, double h}) _disp(double vw, double vh) {
    final a = widget.imgAspect;
    final cover = (vw / a > vh) ? vw / a : vh;
    final contain = (vw / a < vh) ? vw / a : vh;
    final s = _selWindow.zoom <= 0 ? contain : cover * _selWindow.zoom;
    return (w: a * s, h: s);
  }

  void _panStart() => setState(() {
        _dragging = true;
        _liveX = _selWindow.focusX;
        _liveY = _selWindow.focusY;
      });

  void _panBy(Offset delta, double vw, double vh) {
    final disp = _disp(vw, vh);
    setState(() {
      _liveX = _clampFocus(_liveX - delta.dx / disp.w, (vw / 2) / disp.w);
      _liveY = _clampFocus(_liveY - delta.dy / disp.h, (vh / 2) / disp.h);
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
    if (!_expanded) {
      return InkWell(
        onTap: () => setState(() => _expanded = true),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.tune, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text('微調視窗位置（點開，在框內滑動移動圖片）',
                    style: TextStyle(fontSize: 13)),
              ),
              Icon(Icons.expand_more),
            ],
          ),
        ),
      );
    }
    final n = widget.windows.length;
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: '上一個視窗',
              onPressed: _sel > 0 ? () => setState(() => _selected = _sel - 1) : null,
            ),
            Text('視窗 ${_sel + 1} / $n',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: '下一個視窗',
              onPressed:
                  _sel < n - 1 ? () => setState(() => _selected = _sel + 1) : null,
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => setState(() => _expanded = false),
              icon: const Icon(Icons.expand_less),
              label: const Text('收合'),
            ),
          ],
        ),
        Container(
          color: Colors.black,
          constraints: const BoxConstraints(maxHeight: 220),
          padding: const EdgeInsets.only(bottom: 8),
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
      ],
    );
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
