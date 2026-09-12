import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'native_wallpaper.dart';
import 'wallpaper_playlist.dart';
import 'wallpaper_page.dart';

/// In-app wallpaper crop + preview (no system cropper, no external app).
///
/// The image is ALWAYS the original; the crop is stored as a normalized
/// transform ([initialZoom]/[initialFocusX]/[initialFocusY]) so re-entering
/// restores the same view and the user can still zoom out (below "cover") to
/// recover parts that were previously cropped off. On confirm we capture the
/// crop frame to a screen-sized bitmap (WYSIWYG).
///
/// Default (zoom <= 0) = fit the entire image inside the screen, centered,
/// with letterbox bars. Pinch-zoom in to fill / crop.
class WallpaperCropPage extends StatefulWidget {
  const WallpaperCropPage({
    super.key,
    required this.asset,
    this.target,
    this.initialZoom = 0.0,
    this.initialFocusX = 0.5,
    this.initialFocusY = 0.5,
  });

  final AssetEntity asset;
  final WallpaperTarget? target;

  /// Saved crop transform to restore (playlist mode).
  /// <= 0 means "fit entire image, centered" (the default).
  final double initialZoom;
  final double initialFocusX;
  final double initialFocusY;

  @override
  State<WallpaperCropPage> createState() => _WallpaperCropPageState();
}

class _WallpaperCropPageState extends State<WallpaperCropPage>
    with WidgetsBindingObserver {
  final GlobalKey _cropKey = GlobalKey();
  final TransformationController _transform = TransformationController();

  bool _applied = false;
  bool _busy = false;

  int _flags = kFlagSystem;

  double _bw = 0, _bh = 0, _cw = 0, _ch = 0;

  VideoPlayerController? _video;
  String? _videoError;
  bool get _isVideo => widget.asset.type == AssetType.video;
  bool get _videoReady => _video?.value.isInitialized ?? false;
  bool get _canSave => !_busy && (!_isVideo || _videoReady);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isVideo) _loadVideo();
  }

  Future<void> _loadVideo() async {
    try {
      final file = await widget.asset.originFile ?? await widget.asset.file;
      if (!mounted) return;
      if (file == null) throw StateError('影片已移除或無法讀取');
      final controller = VideoPlayerController.file(file);
      _video = controller;
      await controller.initialize();
      if (!mounted) return;
      await controller.setVolume(0);
      await controller.setLooping(true);
      if (!mounted) return;
      await controller.play();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _videoError = '無法播放影片：$e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_videoReady) return;
    if (state == AppLifecycleState.resumed) {
      _video?.play();
    } else {
      _video?.pause();
    }
  }

  Future<void> _openPlaylist() async {
    await _video?.pause();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const WallpaperPage(),
    ));
    if (mounted && _videoReady) await _video?.play();
  }

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
    WidgetsBinding.instance.removeObserver(this);
    _video?.dispose();
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

  Future<void> _saveCropOnly() async {
    if (_busy) return;
    setState(() => _busy = true);
    final t = widget.target!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final (z, fx, fy) = _currentCrop();
      final path = _isVideo ? '' : await NativeWallpaper.saveCrop(
          await _captureBytes(), t.key, widget.asset.id);
      await WallpaperPlaylist.setCropped(t, widget.asset.id, path,
          zoom: z, focusX: fx, focusY: fy,
          sourceWidth: _video?.value.size.width.round(),
          sourceHeight: _video?.value.size.height.round());
      if (!mounted) return;
      messenger.showSnackBar(
          const SnackBar(content: Text('已儲存裁切，請回清單按「套用輪播」更新桌布')));
      navigator.pop();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _setNowPlaylist() async {
    if (_isVideo) return _setVideoWallpaper(saveCrop: true);
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

  Future<void> _setSingle() async {
    if (_isVideo) return _setVideoWallpaper(saveCrop: false);
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

  Future<void> _setVideoWallpaper({required bool saveCrop}) async {
    if (!_canSave) return;
    setState(() => _busy = true);
    try {
      final (z, fx, fy) = _currentCrop();
      final size = _video!.value.size;
      final target = widget.target ?? (_flags == kFlagLock ? WallpaperTarget.lock : WallpaperTarget.home);
      if (saveCrop) {
        await WallpaperPlaylist.setCropped(
          target, widget.asset.id, '',
          zoom: z, focusX: fx, focusY: fy,
          sourceWidth: size.width.round(), sourceHeight: size.height.round(),
        );
      }
      final file = await widget.asset.originFile ?? await widget.asset.file;
      if (file == null) throw StateError('影片已移除或無法讀取');
      await NativeWallpaper.applyLive(
        side: target.key,
        items: [{
          'id': widget.asset.id, 'srcPath': file.path,
          'ext': file.path.split('.').last.toLowerCase(),
          'type': 'video', 'mime': widget.asset.mimeType ?? '',
          'zoom': z, 'focusX': fx, 'focusY': fy, 'animated': false,
          'width': size.width.round(), 'height': size.height.round(),
        }],
        liveSeconds: WallpaperPlaylist.settings.value.secondsFor(target),
        loops: WallpaperPlaylist.settings.value.loopsBeforeNext,
        shuffle: false,
      );
      await _video?.pause();
      await NativeWallpaper.openLiveWallpaperPreview(side: target.key);
      if (!mounted) return;
      setState(() => _busy = false);
      final label = !_isPlaylist && _flags == (kFlagSystem | kFlagLock) ? '主畫面與鎖定畫面' : target.label;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('請在系統預覽選「$label」，影片依裁切範圍靜音循環播放'),
      ));
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
        actions: [
          IconButton(tooltip: '輪播清單', icon: const Icon(Icons.slideshow),
              onPressed: _busy ? null : _openPlaylist),
          IconButton(tooltip: '輪播設定', icon: const Icon(Icons.tune),
              onPressed: _busy ? null : () => showWallpaperSettings(context)),
        ],
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
                        if (_isVideo && !_videoReady) {
                          return Center(child: _videoError == null
                              ? const CircularProgressIndicator()
                              : Padding(padding: const EdgeInsets.all(16),
                                  child: Text(_videoError!,
                                    style: const TextStyle(color: Colors.white))));
                        }
                        final bw = constraints.maxWidth;
                        final bh = constraints.maxHeight;
                        final boxAspect = bw / bh;
                        final iw = _isVideo ? _video!.value.size.width : widget.asset.width.toDouble();
                        final ih = _isVideo ? _video!.value.size.height : widget.asset.height.toDouble();
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
                        const maxScale = 6.0;

                        if (!_applied) {
                          _applied = true;
                          final z = widget.initialZoom <= 0
                              ? minScale
                              : widget.initialZoom
                                  .clamp(minScale, maxScale)
                                  .toDouble();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
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
                            child: _isVideo ? VideoPlayer(_video!) : Image(
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
              '預設把整張置中塞進畫面（多出來的邊留黑）。雙指放大可以切滿螢幕；框內就是桌布範圍。',
              style: TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          if (_animated)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                '主畫面與鎖定輪播都保留動畫；此處單張圖片設定會擷取靜態畫面。',
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
                '「儲存裁切」後請回清單套用輪播；「設為桌布」會套用目前這一項。',
                style: TextStyle(color: Colors.white60, fontSize: 11),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _canSave ? _saveCropOnly : null,
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
                      onPressed: _canSave ? _setNowPlaylist : null,
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
              Text(
                _isVideo ? '影片依裁切範圍靜音循環播放，不更動輪播清單。請在系統預覽選擇相同畫面；若只有「兩者」，會同時更換兩邊。' : '主畫面＝解鎖後的桌面；鎖定＝沒解鎖時的畫面；兩者＝同一張寫入兩邊。此處只設定一次，不影響輪播清單。',
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
                      onPressed: _canSave ? _setSingle : null,
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
