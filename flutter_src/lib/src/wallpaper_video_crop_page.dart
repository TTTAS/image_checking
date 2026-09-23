import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

import 'wallpaper_crop_page.dart';
import 'wallpaper_playlist.dart';

/// Video wallpaper framing — pinch/pan just like the image crop editor.
///
/// The crop is stored as a normalized transform ([zoom]/[focusX]/[focusY]) so
/// the live-wallpaper renderer frames the video the same way it frames a
/// still image. [zoom] <= 0 means "fit the whole video, centered"; pinch in to
/// fill / crop, drag to choose what stays in frame. Re-entering restores the
/// saved framing.
class WallpaperVideoCropPage extends StatefulWidget {
  const WallpaperVideoCropPage({
    super.key,
    required this.asset,
    required this.target,
    this.initialZoom = 0.0,
    this.initialFocusX = 0.5,
    this.initialFocusY = 0.5,
  });

  final AssetEntity asset;
  final WallpaperTarget target;

  /// Saved crop transform to restore. <= 0 zoom = "fit whole video, centered".
  final double initialZoom;
  final double initialFocusX;
  final double initialFocusY;

  @override
  State<WallpaperVideoCropPage> createState() =>
      _WallpaperVideoCropPageState();
}

class _WallpaperVideoCropPageState extends State<WallpaperVideoCropPage> {
  static const Color _frameColor = Color(0xFFFFCA28); // amber

  final TransformationController _transform = TransformationController();

  VideoPlayerController? _controller;
  bool _busy = false;
  bool _applied = false;
  Object? _error;

  // Frame (box) and content (video) dimensions, plus the min "fit" scale.
  double _bw = 0, _bh = 0, _cw = 0, _ch = 0;
  double _minScale = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await widget.asset.file;
      if (file == null) throw StateError('找不到影片檔案');
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
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

  (double, double, double) _currentCrop() {
    final m = _transform.value;
    final zoom = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    if (_cw <= 0 || _ch <= 0 || zoom == 0) return (0.0, 0.5, 0.5);
    final fx = (_bw / 2 - t.x) / (zoom * _cw);
    final fy = (_bh / 2 - t.y) / (zoom * _ch);
    return (zoom, fx, fy);
  }

  /// Snap near-aligned values to the exact target when a gesture ends: focus to
  /// dead centre, zoom to exactly "fit whole video" or "fill screen".
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

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    // A crop sitting at the min "fit" scale means "whole video, centered":
    // store zoom 0 so the renderer letterboxes it, matching the image path.
    var (z, fx, fy) = _currentCrop();
    if (_minScale > 0 && (z - _minScale).abs() < 0.02) {
      z = 0.0;
      fx = 0.5;
      fy = 0.5;
    }
    await WallpaperPlaylist.setTransform(
      widget.target,
      widget.asset.id,
      zoom: z,
      focusX: fx,
      focusY: fy,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(z <= 0 ? '已儲存完整置中顯示' : '已儲存裁切框選')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cropAspect = mq.size.width / mq.size.height;
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('裁切影片（${widget.target.label}）',
            style: const TextStyle(fontSize: 16)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '影片無法預覽：$_error',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    )
                  : !ready
                      ? const CircularProgressIndicator()
                      : AspectRatio(
                          aspectRatio: cropAspect,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRect(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final bw = constraints.maxWidth;
                                    final bh = constraints.maxHeight;
                                    final boxAspect = bw / bh;
                                    final size = controller.value.size;
                                    final iw = size.width;
                                    final ih = size.height;
                                    final vidAspect = (iw > 0 && ih > 0)
                                        ? iw / ih
                                        : boxAspect;
                                    double cw, ch;
                                    if (vidAspect > boxAspect) {
                                      ch = bh;
                                      cw = bh * vidAspect;
                                    } else {
                                      cw = bw;
                                      ch = bw / vidAspect;
                                    }
                                    _bw = bw;
                                    _bh = bh;
                                    _cw = cw;
                                    _ch = ch;
                                    final fitScale = (bw / cw < bh / ch
                                        ? bw / cw
                                        : bh / ch);
                                    final minScale =
                                        fitScale.clamp(0.05, 1.0);
                                    _minScale = minScale;
                                    const maxScale = 6.0;

                                    if (!_applied) {
                                      _applied = true;
                                      final z = widget.initialZoom <= 0
                                          ? minScale
                                          : widget.initialZoom
                                              .clamp(minScale, maxScale)
                                              .toDouble();
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                        _transform.value = _matrixFor(
                                            z,
                                            widget.initialFocusX,
                                            widget.initialFocusY);
                                      });
                                    }

                                    return InteractiveViewer(
                                      transformationController: _transform,
                                      constrained: false,
                                      clipBehavior: Clip.hardEdge,
                                      boundaryMargin: const EdgeInsets.all(
                                          double.infinity),
                                      minScale: minScale,
                                      maxScale: maxScale,
                                      onInteractionEnd: (_) => _snapOnEnd(),
                                      child: SizedBox(
                                        width: cw,
                                        height: ch,
                                        child: VideoPlayer(controller),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const IgnorePointer(
                                child:
                                    CustomPaint(painter: CropGuidesPainter()),
                              ),
                              IgnorePointer(
                                child: AnimatedBuilder(
                                  animation: _transform,
                                  builder: (context, _) => CustomPaint(
                                    painter: CropEdgePainter(
                                      matrix: _transform.value,
                                      cw: _cw,
                                      ch: _ch,
                                    ),
                                  ),
                                ),
                              ),
                              IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: _frameColor, width: 2.5),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '雙指縮放、單指拖曳決定影片要顯示哪一塊——跟序列裡的視窗裁切一樣。'
              '黃框是螢幕邊界；放開手會自動貼齊正中／完整／滿版。',
              style: TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(_busy ? '儲存中…' : '儲存裁切'),
                      onPressed:
                          _busy || !ready || _error != null ? null : _save,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    style:
                        OutlinedButton.styleFrom(foregroundColor: Colors.white),
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
