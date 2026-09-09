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
/// The image sits inside a crop frame whose aspect ratio matches the screen; the
/// user pans / pinch-zooms, and whatever shows inside the frame is exactly what
/// gets set (WYSIWYG). On confirm we capture the frame to a screen-sized bitmap
/// and hand the bytes to the native side, which only decodes + setBitmap for the
/// chosen screens (home / lock / both). The wallpaper is never touched until the
/// user taps 設為桌布.
class WallpaperCropPage extends StatefulWidget {
  const WallpaperCropPage({super.key, required this.asset});

  final AssetEntity asset;

  @override
  State<WallpaperCropPage> createState() => _WallpaperCropPageState();
}

class _WallpaperCropPageState extends State<WallpaperCropPage> {
  final GlobalKey _cropKey = GlobalKey();
  final TransformationController _transform = TransformationController();

  // Center the (cover-sized) image on the crop frame once, on first layout.
  bool _centered = false;

  // Which screens to write to. Default = home only, so we never silently
  // overwrite the lock screen too.
  int _flags = WallpaperSettings.flagSystem;
  bool _busy = false;

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

  Future<void> _apply() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final mq = MediaQuery.of(context);
    try {
      final boundary =
          _cropKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      // Capture at ~screen resolution: output width ≈ real screen pixels.
      final screenWpx = mq.size.width * mq.devicePixelRatio;
      final pr = (screenWpx / boundary.size.width).clamp(1.0, 4.0);
      final image = await boundary.toImage(pixelRatio: pr);
      final bd = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bd == null) throw StateError('擷取影像失敗');
      final bytes = bd.buffer.asUint8List();

      final honored = await NativeWallpaper.setWallpaperBytes(bytes, _flags);
      if (!mounted) return;
      final where = _flags == (WallpaperSettings.flagSystem | WallpaperSettings.flagLock)
          ? '主畫面與鎖定畫面'
          : (_flags == WallpaperSettings.flagLock ? '鎖定畫面' : '主畫面');
      var msg = '已設為$where的桌布';
      if (!honored && _flags != WallpaperSettings.flagSystem) {
        msg += '（此裝置較舊，無法分開主畫面／鎖定，已套用單一桌布）';
      }
      messenger.showSnackBar(SnackBar(content: Text(msg)));
      navigator.pop();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
          SnackBar(content: Text('設定失敗：${e.message ?? e.code}')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('設定失敗：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cropAspect = mq.size.width / mq.size.height;
    final screenWpx = (mq.size.width * mq.devicePixelRatio).round();
    // Cap decode to the screen width so huge photos don't blow up memory.
    final provider = ResizeImage(
      AssetEntityImageProvider(widget.asset, isOriginal: true),
      width: screenWpx,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('裁切桌布', style: TextStyle(fontSize: 16)),
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
                        final iw = widget.asset.width.toDouble();
                        final ih = widget.asset.height.toDouble();
                        final imgAspect =
                            (iw > 0 && ih > 0) ? iw / ih : (bw / bh);
                        final boxAspect = bw / bh;
                        // "cover": short edge = frame, long edge overflows so it
                        // can be panned; never smaller than the frame.
                        double cw, ch;
                        if (imgAspect > boxAspect) {
                          ch = bh;
                          cw = bh * imgAspect;
                        } else {
                          cw = bw;
                          ch = bw / imgAspect;
                        }
                        if (!_centered) {
                          _centered = true;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _transform.value = Matrix4.identity()
                              ..translate(-(cw - bw) / 2, -(ch - bh) / 2);
                          });
                        }
                        return InteractiveViewer(
                          transformationController: _transform,
                          constrained: false,
                          clipBehavior: Clip.hardEdge,
                          minScale: 1.0,
                          maxScale: 6.0,
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
              '拖曳移動、雙指縮放；框內就是會被設成桌布的範圍。',
              style: TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '這裡只設定目前桌布。輪播仍用原圖；要輪播鎖定畫面請到設定→套用範圍。',
              style: TextStyle(color: Colors.white54, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
          if (_animated)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                '動態圖片只會擷取單一靜態畫面（會動要等 M3）。',
                style: TextStyle(color: Colors.white54, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
          _BottomBar(
            flags: _flags,
            busy: _busy,
            onFlags: (f) => setState(() => _flags = f),
            onApply: _apply,
            onCancel: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.flags,
    required this.busy,
    required this.onFlags,
    required this.onApply,
    required this.onCancel,
  });

  final int flags;
  final bool busy;
  final ValueChanged<int> onFlags;
  final VoidCallback onApply;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    const both = WallpaperSettings.flagSystem | WallpaperSettings.flagLock;
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
                '主畫面＝解鎖後的桌面；鎖定＝沒解鎖時的畫面；兩者＝同一張寫入兩邊。',
                style: TextStyle(color: Colors.white60, fontSize: 11),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                      value: WallpaperSettings.flagSystem, label: Text('主畫面')),
                  ButtonSegment(
                      value: WallpaperSettings.flagLock, label: Text('鎖定')),
                  ButtonSegment(value: both, label: Text('兩者')),
                ],
                selected: {flags},
                onSelectionChanged:
                    busy ? null : (sel) => onFlags(sel.first),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wallpaper),
                      label: Text(busy ? '設定中…' : '設為桌布'),
                      onPressed: busy ? null : onApply,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: busy ? null : onCancel,
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
