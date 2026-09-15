import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

import 'wallpaper_playlist.dart';

/// Video wallpaper framing preview.
///
/// Videos default to [BoxFit.contain] so the complete frame remains visible.
/// The user can switch to a centered fill/crop before applying the playlist.
class WallpaperVideoCropPage extends StatefulWidget {
  const WallpaperVideoCropPage({
    super.key,
    required this.asset,
    required this.target,
    required this.initialZoom,
  });

  final AssetEntity asset;
  final WallpaperTarget target;
  final double initialZoom;

  @override
  State<WallpaperVideoCropPage> createState() =>
      _WallpaperVideoCropPageState();
}

class _WallpaperVideoCropPageState extends State<WallpaperVideoCropPage> {
  VideoPlayerController? _controller;
  bool _fill = false;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _fill = widget.initialZoom > 0;
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
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    await WallpaperPlaylist.setTransform(
      widget.target,
      widget.asset.id,
      zoom: _fill ? 1.0 : 0.0,
      focusX: 0.5,
      focusY: 0.5,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_fill ? '已儲存置中填滿裁切' : '已儲存完整置中顯示')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('裁切（${widget.target.label}）',
            style: const TextStyle(fontSize: 16)),
      ),
      body: Column(
        children: [
          Expanded(
            child: ClipRect(
              child: ColoredBox(
                color: Colors.black,
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
                      : controller == null || !controller.value.isInitialized
                          ? const CircularProgressIndicator()
                          : SizedBox.expand(
                              child: FittedBox(
                                fit: _fill ? BoxFit.cover : BoxFit.contain,
                                clipBehavior: Clip.hardEdge,
                                child: SizedBox(
                                  width: controller.value.size.width,
                                  height: controller.value.size.height,
                                  child: VideoPlayer(controller),
                                ),
                              ),
                            ),
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text(
              '預設「完整」會保留整個影片；選「填滿」會置中放大並裁掉超出螢幕的部分。',
              style: TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.fit_screen),
                  label: Text('完整'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.crop_free),
                  label: Text('填滿'),
                ),
              ],
              selected: {_fill},
              onSelectionChanged: _busy
                  ? null
                  : (value) => setState(() => _fill = value.first),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
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
                          _busy || controller == null || _error != null
                              ? null
                              : _save,
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
