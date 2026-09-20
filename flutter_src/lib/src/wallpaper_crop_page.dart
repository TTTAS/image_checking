import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'native_wallpaper.dart';
import 'wallpaper_playlist.dart';

/// In-app wallpaper crop + preview (no system cropper, no external app).
///
/// The image is ALWAYS the original; the crop is stored as a normalized
/// transform ([initialZoom]/[initialFocusX]/[initialFocusY]) so re-entering
/// restores the same view and the user can still zoom out (below "cover") to
/// recover parts that were previously cropped off.
///
/// Two modes:
///  * Default: a "set as wallpaper" screen that captures the crop frame to a
///    screen-sized bitmap and writes it as the wallpaper (used from the viewer).
///  * [pickWindow] = true: a framing picker used by the window-sequence editor.
///    It does NOT touch the wallpaper; confirming pops a [CropWindow] describing
///    the chosen zoom/focus.
///
/// Default (zoom <= 0) = fit the entire image inside the screen, centered,
/// with letterbox bars. Pinch-zoom in to fill / crop.
class WallpaperCropPage extends StatefulWidget {
  const WallpaperCropPage({
    super.key,
    required this.asset,
    this.pickWindow = false,
    this.initialZoom = 0.0,
    this.initialFocusX = 0.5,
    this.initialFocusY = 0.5,
  });

  final AssetEntity asset;

  /// When true, the page returns a [CropWindow] instead of setting a wallpaper.
  final bool pickWindow;

  /// Saved crop transform to restore.
  /// <= 0 means "fit entire image, centered" (the default).
  final double initialZoom;
  final double initialFocusX;
  final double initialFocusY;

  @override
  State<WallpaperCropPage> createState() => _WallpaperCropPageState();
}

class _WallpaperCropPageState extends State<WallpaperCropPage> {
  /// Outline drawn around the wallpaper frame so its boundary is visible even
  /// when the default framing leaves black letterbox bars on a black page.
  static const Color _frameColor = Color(0xFFFFCA28); // amber

  final GlobalKey _cropKey = GlobalKey();
  final TransformationController _transform = TransformationController();

  bool _busy = false;
  bool _applied = false;

  int _flags = kFlagSystem;

  double _bw = 0, _bh = 0, _cw = 0, _ch = 0;
  double _minScale = 0;

  bool get _animated {
    final m = (widget.asset.mimeType ?? '').toLowerCase();
    final t = (widget.asset.title ?? '').toLowerCase();
    return m.contains('gif') ||
        m.contains('webp') ||
        t.endsWith('.gif') ||
        t.endsWith('.webp');
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Matrix4 _matrixFor(double zoom, double fx, double fy) {
    final tx = _bw / 2 - zoom * (fx * _cw);
    final ty = _bh / 2 - zoom * (fy * _ch);
    return Matrix4.identity()
      ..translate(tx, ty)
      ..scale(zoom);
  }

  /// After a pan/zoom gesture ends, nudge near-aligned values to the exact
  /// target so a crop that is "off by a hair" lands cleanly: focus snaps to the
  /// exact centre, and zoom snaps to exactly "fit whole image" or "fill screen".
  void _snapOnEnd() {
    if (_cw <= 0 || _ch <= 0) return;
    var (z, fx, fy) = _currentCrop();
    const posTol = 0.025;
    const zoomTol = 0.06;
    if ((fx - 0.5).abs() < posTol) fx = 0.5;
    if ((fy - 0.5).abs() < posTol) fy = 0.5;
    if (_minScale > 0 && (z - _minScale).abs() < zoomTol) {
      z = _minScale;
    } else if ((z - 1.0).abs() < zoomTol) {
      z = 1.0;
    }
    _transform.value = _matrixFor(z, fx, fy);
  }

  (double, double, double) _currentCrop() {
    final m = _transform.value;
    final zoom = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    if (_cw <= 0 || _ch <= 0 || zoom == 0) return (0.0, 0.5, 0.5);
    final fx = (_bw / 2 - t.x) / (zoom * _cw);
    final fy = (_bh / 2 - t.y) / (zoom * _ch);
    return (zoom, fx, fy);
  }

  Future<Uint8List> _captureBytes() async {
    final mq = MediaQuery.of(context);
    final boundary =
        _cropKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final screenWpx = mq.size.width * mq.devicePixelRatio;
    final pr = (screenWpx / boundary.size.width).clamp(1.0, 4.0);
    final image = await boundary.toImage(pixelRatio: pr);
    final bd = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bd == null) throw StateError('擷取影像失敗');
    return bd.buffer.asUint8List();
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() => _busy = false);
    final m = e is PlatformException ? (e.message ?? e.code) : '$e';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('操作失敗：$m')));
  }

  /// Window-picker mode: pop the chosen framing back to the sequence editor.
  void _confirmPick() {
    final (z, fx, fy) = _currentCrop();
    Navigator.of(context)
        .pop(CropWindow(zoom: z, focusX: fx, focusY: fy));
  }

  Future<void> _setSingle() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final bytes = await _captureBytes();
      final honored = await NativeWallpaper.setWallpaperBytes(bytes, _flags);
      if (!mounted) return;
      final where = _flags == (kFlagSystem | kFlagLock)
          ? '主畫面與鎖定畫面'
          : (_flags == kFlagLock ? '鎖定畫面' : '主畫面');
      var msg = '已設為$where的桌布';
      if (!honored && _flags != kFlagSystem) {
        msg += '（此裝置較舊，無法分開，已套用單一桌布）';
      }
      messenger.showSnackBar(SnackBar(content: Text(msg)));
      navigator.pop();
    } catch (e) {
      _fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cropAspect = mq.size.width / mq.size.height;
    final screenWpx = (mq.size.width * mq.devicePixelRatio).round();
    final provider = ResizeImage(
      AssetEntityImageProvider(widget.asset, isOriginal: true),
      width: screenWpx,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.pickWindow ? '選擇視窗範圍' : '裁切桌布',
          style: const TextStyle(fontSize: 16),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: cropAspect,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                  key: _cropKey,
                  child: ClipRect(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final bw = constraints.maxWidth;
                        final bh = constraints.maxHeight;
                        final boxAspect = bw / bh;
                        final iw = widget.asset.width.toDouble();
                        final ih = widget.asset.height.toDouble();
                        final imgAspect =
                            (iw > 0 && ih > 0) ? iw / ih : boxAspect;
                        double cw, ch;
                        if (imgAspect > boxAspect) {
                          ch = bh;
                          cw = bh * imgAspect;
                        } else {
                          cw = bw;
                          ch = bw / imgAspect;
                        }
                        _bw = bw;
                        _bh = bh;
                        _cw = cw;
                        _ch = ch;
                        final fitScale = (bw / cw < bh / ch ? bw / cw : bh / ch);
                        final minScale = fitScale.clamp(0.05, 1.0);
                        _minScale = minScale;
                        const maxScale = 6.0;

                        if (!_applied) {
                          _applied = true;
                          final z = widget.initialZoom <= 0
                              ? minScale
                              : widget.initialZoom
                                  .clamp(minScale, maxScale)
                                  .toDouble();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _transform.value = _matrixFor(
                                z, widget.initialFocusX, widget.initialFocusY);
                          });
                        }

                        return InteractiveViewer(
                          transformationController: _transform,
                          constrained: false,
                          clipBehavior: Clip.hardEdge,
                          boundaryMargin: const EdgeInsets.all(double.infinity),
                          minScale: minScale,
                          maxScale: maxScale,
                          onInteractionEnd: (_) => _snapOnEnd(),
                          child: SizedBox(
                            width: cw,
                            height: ch,
                            child: Image(
                              image: provider,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (context, error, stack) =>
                                  const Center(
                                child: Icon(Icons.broken_image_outlined,
                                    color: Colors.white54, size: 40),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                    ),
                    // Alignment guides (rule-of-thirds grid + centre crosshair)
                    // and the frame outline both sit OUTSIDE the RepaintBoundary
                    // above, so they help you line the crop up on screen but are
                    // never captured into the saved wallpaper image.
                    const IgnorePointer(
                      child: CustomPaint(painter: _GuidesPainter()),
                    ),
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: _frameColor, width: 2.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              '黃色外框是螢幕（桌布）邊界；九宮格與中央十字線幫你對齊。'
              '雙指縮放平移，放開手時會自動貼齊正中／完整／滿版，框內就是這個視窗顯示的範圍。',
              style: TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          if (_animated)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                '動態圖片只會擷取單一靜態畫面。',
                style: TextStyle(color: Colors.white54, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
          widget.pickWindow ? _pickBar() : _singleBar(),
        ],
      ),
    );
  }

  Widget _pickBar() {
    return Material(
      color: Colors.black,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('使用這個視窗'),
                  onPressed: _confirmPick,
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _singleBar() {
    const both = kFlagSystem | kFlagLock;
    return Material(
      color: Colors.black,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '主畫面＝解鎖後的桌面；鎖定＝沒解鎖時的畫面；兩者＝同一張寫入兩邊。此處只設定一次，不影響輪播清單。',
                style: TextStyle(color: Colors.white60, fontSize: 11),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: kFlagSystem, label: Text('主畫面')),
                  ButtonSegment(value: kFlagLock, label: Text('鎖定')),
                  ButtonSegment(value: both, label: Text('兩者')),
                ],
                selected: {_flags},
                onSelectionChanged:
                    _busy ? null : (sel) => setState(() => _flags = sel.first),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wallpaper),
                      label: Text(_busy ? '設定中…' : '設為桌布'),
                      onPressed: _busy ? null : _setSingle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rule-of-thirds grid plus a brighter centre crosshair, drawn over the crop
/// frame to help line the picture up. Painted outside the capture boundary, so
/// none of these lines appear in the saved wallpaper.
class _GuidesPainter extends CustomPainter {
  const _GuidesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final thirds = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    // Vertical + horizontal thirds.
    for (var i = 1; i <= 2; i++) {
      final x = size.width * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), thirds);
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), thirds);
    }
    // Centre crosshair, brighter so "dead centre" is easy to hit.
    final center = Paint()
      ..color = const Color(0xFFFFCA28).withValues(alpha: 0.7)
      ..strokeWidth = 1.4;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      center,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      center,
    );
  }

  @override
  bool shouldRepaint(covariant _GuidesPainter oldDelegate) => false;
}
