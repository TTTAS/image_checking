import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:video_player/video_player.dart';

import 'collections.dart';
import 'library.dart';
import 'photo_actions.dart';
import 'wallpaper_crop_page.dart';
import 'wallpaper_page.dart';
import 'wallpaper_playlist.dart';

/// Full-screen viewer: swipe between photos, pinch-zoom, and act on a single
/// photo (favorite / edit / share / hide / delete).
class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.assets,
    required this.initialIndex,
  });

  final List<AssetEntity> assets;
  final int initialIndex;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final PageController _controller;
  late List<AssetEntity> _assets;
  late int _index;

  @override
  void initState() {
    super.initState();
    _assets = List<AssetEntity>.from(widget.assets);
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  AssetEntity get _current => _assets[_index];

  Future<void> _delete() async {
    final deleted = await PhotoActions.delete([_current]);
    if (deleted.isEmpty) return;
    PhotoLibrary.instance.removeIds(deleted);
    if (!mounted) return;
    setState(() {
      _assets.removeAt(_index);
      if (_index >= _assets.length) _index = _assets.length - 1;
    });
    if (_assets.isEmpty && mounted) Navigator.of(context).pop();
  }

  void _showInfo() {
    final asset = _current;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return FutureBuilder<Map<String, String>>(
          future: _collectInfo(asset),
          builder: (ctx, snap) {
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final info = snap.data!;
            return SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      '詳細資訊',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                  ),
                  for (final e in info.entries)
                    ListTile(
                      dense: true,
                      title: Text(e.key,
                          style: const TextStyle(fontSize: 12)),
                      subtitle: Text(e.value,
                          style: const TextStyle(fontSize: 15)),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _addToPlaylist(List<WallpaperTarget> targets) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    var any = false;
    for (final t in targets) {
      if (await WallpaperPlaylist.add(_current, t)) any = true;
    }
    if (!mounted) return;
    final label = targets.length >= 2 ? '主畫面與鎖定' : targets.first.label;
    messenger.showSnackBar(SnackBar(
      content: Text(any ? '已加入$label輪播' : '無法加入（不支援的格式或已在清單中）'),
      action: any
          ? SnackBarAction(
              label: '檢視',
              onPressed: () => navigator.push(
                MaterialPageRoute<void>(
                    builder: (_) =>
                        WallpaperPage(initialTarget: targets.first)),
              ),
            )
          : null,
    ));
  }

  Future<Map<String, String>> _collectInfo(AssetEntity a) async {
    final file = await a.file;
    final bytes = file != null ? await file.length() : 0;
    final lat = a.latitude ?? 0;
    final lng = a.longitude ?? 0;
    return {
      '檔名': a.title ?? '(未知)',
      '尺寸': '${a.width} × ${a.height}',
      '檔案大小': _formatBytes(bytes),
      '拍攝時間': _formatDate(a.createDateTime),
      '修改時間': _formatDate(a.modifiedDateTime),
      '類型': a.mimeType ?? '(未知)',
      if (lat != 0 || lng != 0)
        '位置': '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
      if ((a.relativePath ?? '').isNotEmpty) '路徑': a.relativePath!,
    };
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_assets.isEmpty) return const SizedBox.shrink();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _current.title ?? '${_index + 1} / ${_assets.length}',
          style: const TextStyle(fontSize: 15),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_current.type != AssetType.video)
            PopupMenuButton<String>(
              icon: const Icon(Icons.wallpaper),
              tooltip: '桌布',
              onSelected: (v) {
                switch (v) {
                  case 'single':
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => WallpaperCropPage(asset: _current),
                    ));
                    break;
                  case 'home':
                    _addToPlaylist([WallpaperTarget.home]);
                    break;
                  case 'lock':
                    _addToPlaylist([WallpaperTarget.lock]);
                    break;
                  case 'both':
                    _addToPlaylist(
                        [WallpaperTarget.home, WallpaperTarget.lock]);
                    break;
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'single', child: Text('設為桌布（單張）')),
                PopupMenuItem(value: 'home', child: Text('加入主畫面輪播')),
                PopupMenuItem(value: 'lock', child: Text('加入鎖定輪播')),
                PopupMenuItem(value: 'both', child: Text('兩邊都加入輪播')),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '詳細資訊',
            onPressed: _showInfo,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: _assets.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          final asset = _assets[i];
          if (asset.type == AssetType.video) {
            return _VideoView(key: ValueKey(asset.id), asset: asset);
          }
          return InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: AssetEntityImage(
                asset,
                isOriginal: true,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white54,
                  size: 48,
                ),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: Listenable.merge([
          AppCollections.favorites,
          AppCollections.hidden,
        ]),
        builder: (context, _) {
          final id = _current.id;
          final fav = AppCollections.isFavorite(id);
          final hidden = AppCollections.isHidden(id);
          return BottomAppBar(
            color: Colors.black,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _action(
                  icon: fav ? Icons.favorite : Icons.favorite_border,
                  color: fav ? Colors.redAccent : Colors.white,
                  label: '最愛',
                  onTap: () => AppCollections.toggleFavorite(id),
                ),
                if (_current.type != AssetType.video)
                  _action(
                    icon: Icons.tune,
                    label: '編輯',
                    onTap: () => PhotoActions.openEditor(context, _current),
                  ),
                _action(
                  icon: Icons.share_outlined,
                  label: '分享',
                  onTap: () => PhotoActions.share([_current]),
                ),
                _action(
                  icon: hidden ? Icons.visibility : Icons.visibility_off_outlined,
                  label: hidden ? '取消隱藏' : '隱藏',
                  onTap: () => AppCollections.toggleHidden(id),
                ),
                _action(
                  icon: Icons.delete_outline,
                  label: '刪除',
                  onTap: _delete,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// Plays a single video inside the viewer: tap to play/pause, double-tap the
/// left/right half to seek ±10s, a scrub bar, and a button to go full-screen.
class _VideoView extends StatefulWidget {
  const _VideoView({super.key, required this.asset});

  final AssetEntity asset;

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
  VideoPlayerController? _controller;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await widget.asset.file;
      if (file == null) {
        if (mounted) setState(() => _error = true);
        return;
      }
      final c = VideoPlayerController.file(file);
      await c.initialize();
      await c.setLooping(true);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _openFullscreen() {
    final c = _controller;
    if (c == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _FullscreenVideoPage(controller: c),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return const Center(
        child: Icon(Icons.videocam_off_outlined,
            color: Colors.white54, size: 48),
      );
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return _VideoControls(
      controller: c,
      fullscreen: false,
      onToggleFullscreen: _openFullscreen,
    );
  }
}

/// Full-screen video page. Reuses the existing [VideoPlayerController] so
/// playback continues seamlessly, hides the system bars, allows the device to
/// rotate to landscape, and exposes a button to manually flip the orientation.
class _FullscreenVideoPage extends StatefulWidget {
  const _FullscreenVideoPage({required this.controller});

  final VideoPlayerController controller;

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  bool _landscape = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _applyOrientation();
  }

  void _applyOrientation() {
    SystemChrome.setPreferredOrientations(_landscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ]);
  }

  void _toggleOrientation() {
    setState(() => _landscape = !_landscape);
    _applyOrientation();
  }

  @override
  void dispose() {
    // Restore the normal chrome and let the app follow device auto-rotate.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _VideoControls(
        controller: widget.controller,
        fullscreen: true,
        onToggleFullscreen: () => Navigator.of(context).maybePop(),
        onRotate: _toggleOrientation,
      ),
    );
  }
}

/// Interactive video surface + controls shared by the inline viewer and the
/// full-screen page: tap to play/pause, double-tap the left/right half to seek
/// ±10 s, a scrub bar with timestamps, and full-screen / rotation buttons.
class _VideoControls extends StatefulWidget {
  const _VideoControls({
    required this.controller,
    required this.fullscreen,
    this.onToggleFullscreen,
    this.onRotate,
  });

  final VideoPlayerController controller;
  final bool fullscreen;
  final VoidCallback? onToggleFullscreen;
  final VoidCallback? onRotate;

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  Timer? _flashTimer;
  bool _flashVisible = false;
  bool _flashForward = true;

  VideoPlayerController get _c => widget.controller;

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  void _togglePlay() {
    if (_c.value.isPlaying) {
      _c.pause();
    } else {
      _c.play();
    }
    setState(() {});
  }

  void _seekBy(int seconds) {
    final duration = _c.value.duration;
    var target = _c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    _c.seekTo(target);
    _flashTimer?.cancel();
    setState(() {
      _flashForward = seconds > 0;
      _flashVisible = true;
    });
    _flashTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _flashVisible = false);
    });
  }

  static String _fmt(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: _c.value.aspectRatio,
            child: VideoPlayer(_c),
          ),
        ),
        // Left / right double-tap seek zones (single tap toggles play).
        Positioned.fill(
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _togglePlay,
                  onDoubleTap: () => _seekBy(-10),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _togglePlay,
                  onDoubleTap: () => _seekBy(10),
                ),
              ),
            ],
          ),
        ),
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: _c,
          builder: (context, value, _) {
            if (value.isPlaying) return const SizedBox.shrink();
            return const IgnorePointer(
              child: Icon(Icons.play_circle_fill,
                  size: 64, color: Colors.white70),
            );
          },
        ),
        if (_flashVisible)
          Align(
            alignment:
                _flashForward ? Alignment.centerRight : Alignment.centerLeft,
            child: IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _flashForward ? Icons.forward_10 : Icons.replay_10,
                      color: Colors.white,
                      size: 44,
                    ),
                    const SizedBox(height: 4),
                    const Text('10 秒',
                        style: TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _bottomBar(),
        ),
      ],
    );
  }

  Widget _bottomBar() {
    return Container(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        bottom: widget.fullscreen ? 16 : 4,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black54],
        ),
      ),
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: _c,
        builder: (context, value, _) {
          return Row(
            children: [
              IconButton(
                icon: Icon(
                  value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: _togglePlay,
              ),
              Text(
                _fmt(value.position),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: VideoProgressIndicator(
                    _c,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              Text(
                _fmt(value.duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              if (widget.onRotate != null)
                IconButton(
                  icon: const Icon(Icons.screen_rotation, color: Colors.white),
                  tooltip: '旋轉螢幕',
                  onPressed: widget.onRotate,
                ),
              if (widget.onToggleFullscreen != null)
                IconButton(
                  icon: Icon(
                    widget.fullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    color: Colors.white,
                  ),
                  tooltip: widget.fullscreen ? '退出全螢幕' : '全螢幕',
                  onPressed: widget.onToggleFullscreen,
                ),
            ],
          );
        },
      ),
    );
  }
}
