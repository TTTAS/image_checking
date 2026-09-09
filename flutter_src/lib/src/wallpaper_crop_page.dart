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
/// recover parts that were previously cropped off. On confirm we capture the
/// crop frame to a screen-sized bitmap (WYSIWYG).
///
/// Two modes:
///  * playlist ([target] != null): "儲存裁切" saves the crop file + transform into
///    that list (no wallpaper change); "設為桌布" also sets that side now
///    (home=FLAG_SYSTEM, lock=FLAG_LOCK).
///  * single ([target] == null, from the viewer): a one-off set with a
///    home/lock/both chooser; does not touch any playlist.
class WallpaperCropPage extends StatefulWidget {
  const WallpaperCropPage({
    super.key,
    required this.asset,
    this.target,
    this.initialZoom = 1.0,
    this.initialFocusX = 0.5,
    this.initialFocusY = 0.5,
  });

  final AssetEntity asset;
  final WallpaperTarget? target;

  /// Saved crop transform to restore (playlist mode). Defaults == cover-centered.
  final double initialZoom;
  final double initialFocusX;
  final double initialFocusY;

  @override
  State<WallpaperCropPage> createState() => _WallpaperCropPageState();
}

class _WallpaperCropPageState extends State<WallpaperCropPage> {
  final GlobalKey _cropKey = GlobalKey();
  final TransformationController _transform = TransformationController();

  bool _applied = false;
  bool _busy = false;

  // Single-mode target screens (home by default). Unused in playlist mode.
  int _flags = kFlagSystem;

  // Cached layout, updated each build; used to convert the transform to/from
  // normalized (zoom, focus) values.
  double _bw = 0, _bh = 0, _cw = 0, _ch = 0;

  bool get _isPlaylist => widget.target != null;

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

  /// Builds the transform that puts original point (fx,fy) at the crop-box center
  /// at scale [zoom] (relative to cover). Child coords are the cover-sized box.
  Matrix4 _matrixFor(double zoom, double fx, double fy) {
    final tx = _bw / 2 - zoom * (fx * _cw);
    final ty = _bh / 2 - zoom * (fy * _ch);
    return Matrix4.identity()
      ..translate(tx, ty)
      ..scale(zoom);
  }

  /// Reads the current (zoom, focusX, focusY) from the live transform.
  (double, double, double) _currentCrop() {
    final m = _transform.value;
    final zoom = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    if (_cw <= 0 || _ch <= 0 || zoom == 0) return (1.0, 0.5, 0.5);
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

  // Playlist mode: save the crop file + transform only (no wallpaper change).
  Future<void> _saveCropOnly() async {
    if (_busy) return;
    setState(() => _busy = true);
    final t = widget.target!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final (z, fx, fy) = _currentCrop();
      final bytes = await _captureBytes();
      final path = await NativeWallpaper.saveCrop(bytes, t.key, widget.asset.id);
      await WallpaperPlaylist.setCropped(t, widget.asset.id, path,
          zoom: z, focusX: fx, focusY: fy);
      if (!mounted) return;
      messenger.showSnackBar(
          const SnackBar(content: Text('已儲存裁切（不會立刻換桌布，下次輪播會用它）')));
      navigator.pop();
    } catch (e) {
      _fail(e);
    }
  }

  // Playlist mode: save the crop AND set that side now.
  Future<void> _setNowPlaylist() async {
    if (_busy) return;
    setState(() => _busy = true);
    final t = widget.target!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final (z, fx, fy) = _currentCrop();
      final bytes = await _captureBytes();
      final path = await NativeWallpaper.saveCrop(bytes, t.key, widget.asset.id);
      await WallpaperPlaylist.setCropped(t, widget.asset.id, path,
          zoom: z, focusX: fx, focusY: fy);
      final honored = await NativeWallpaper.setWallpaperBytes(bytes, t.flag);
      if (!mounted) return;
      var msg = '已設為${t.label}的桌布，並存為裁切';
      if (!honored && t.flag != kFlagSystem) {
        msg += '（此裝置較舊，無法分開，已套用單一桌布）';
      }
      messenger.showSnackBar(SnackBar(content: Text(msg)));
      navigator.pop();
    } catch (e) {
      _fail(e);
    }
  }

  // Single mode (from viewer): one-off set, no playlist write.
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
    // Always the original image; capped to the screen width to bound memory.
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
          _isPlaylist ? '裁切（${widget.target!.label}）' : '裁切桌布',
          style: const TextStyle(fontSize: 16),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: cropAspect,
                child: RepaintBoundary(
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
                        // Cover size of the ORIGINAL relative to the crop box.
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
                        // Scale (relative to cover) at which the whole original
                        // fits inside the box — the minimum, so cut-off parts can
                        // be recovered.
                        final fitScale = (bw / cw < bh / ch ? bw / cw : bh / ch);
                        final minScale = fitScale.clamp(0.05, 1.0);
                        final maxScale = 6.0;

                        if (!_applied) {
                          _applied = true;
                          final z = widget.initialZoom
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
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              '拖曳移動、雙指縮放（可縮小把被切掉的部分拿回來）；框內就是會被設成桌布的範圍。',
              style: TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          if (_animated)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                '動態圖片只會擷取單一靜態畫面（會動要等 M3）。',
                style: TextStyle(color: Colors.white54, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
          _isPlaylist ? _playlistBar() : _singleBar(),
        ],
      ),
    );
  }

  Widget _playlistBar() {
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
                '「儲存裁切」只更新這張的裁切、不會立刻換桌布；「設為桌布」會存並立刻套用這一邊。',
                style: TextStyle(color: Colors.white60, fontSize: 11),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _saveCropOnly,
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white),
                      child: const Text('儲存裁切'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wallpaper),
                      label: Text(_busy ? '處理中…' : '設為桌布'),
                      onPressed: _busy ? null : _setNowPlaylist,
                    ),
                  ),
                ],
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
