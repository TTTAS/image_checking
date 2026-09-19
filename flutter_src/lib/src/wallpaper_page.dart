import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import 'native_wallpaper.dart';
import 'wallpaper_playlist.dart';
import 'wallpaper_sequence_page.dart';
import 'wallpaper_video_crop_page.dart';
import 'widgets.dart';

class WallpaperPage extends StatefulWidget {
  const WallpaperPage({super.key, this.initialTarget = WallpaperTarget.home});

  final WallpaperTarget initialTarget;

  @override
  State<WallpaperPage> createState() => _WallpaperPageState();
}

class _WallpaperPageState extends State<WallpaperPage>
    with WidgetsBindingObserver {
  final Map<String, Future<AssetEntity?>> _assetCache = {};
  late WallpaperTarget _tab = widget.initialTarget;

  Future<AssetEntity?> _asset(String id) =>
      _assetCache[id] ??= AssetEntity.fromId(id);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _showPlaybackError();
  }

  Future<void> _showPlaybackError() async {
    try {
      final message = await NativeWallpaper.liveWallpaperError();
      if (!mounted || message.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 8)),
      );
    } catch (_) {}
  }

  Future<void> _openDiagnostics() async {
    String message;
    try {
      message = await NativeWallpaper.liveWallpaperDiagnostics();
      if (message.isEmpty) message = '尚未記錄播放錯誤。請套用輪播後再查看。';
    } catch (e) {
      message = '無法讀取播放診斷：$e';
    }
    if (!mounted) return;
    final details = '版本 1.0.9+10\n$message';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('播放診斷'),
        content: SingleChildScrollView(child: SelectableText(details)),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: details)),
            child: const Text('複製'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('關閉'),
          ),
        ],
      ),
    );
  }

  Future<void> _openCrop(WallpaperTarget target, WallpaperItem item) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final asset = await _asset(item.id);
    if (asset == null) {
      messenger.showSnackBar(const SnackBar(content: Text('找不到原始圖片')));
      return;
    }
    final initialZoom = item.windows.isNotEmpty ? item.windows.first.zoom : 0.0;
    if (asset.type == AssetType.video || item.isVideo) {
      navigator.push(MaterialPageRoute<void>(
        builder: (_) => WallpaperVideoCropPage(
          asset: asset,
          target: target,
          initialZoom: initialZoom,
        ),
      ));
      return;
    }
    // Images open the window-sequence editor: one image can hold several
    // ordered framings, all as a single playlist item.
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => WallpaperSequencePage(asset: asset, target: target),
    ));
  }

  /// Static rotation renders one bitmap per window (in order) for each item, so
  /// a multi-window item contributes several frames to the timed rotation.
  Future<List<String>> _resolvePaths(
      List<WallpaperItem> items, WallpaperTarget t) async {
    final paths = <String>[];
    for (final it in items) {
      try {
        final asset = await _asset(it.id);
        final file = await asset?.file;
        if (file == null) continue;
        for (var w = 0; w < it.windows.length; w++) {
          final win = it.windows[w];
          try {
            final path = await NativeWallpaper.renderCropSave(
              file.path,
              t.key,
              '${it.id}_w$w',
              zoom: win.zoom,
              focusX: win.focusX,
              focusY: win.focusY,
            );
            if (path.isNotEmpty) paths.add(path);
          } catch (_) {}
        }
      } catch (_) {}
    }
    return paths;
  }

  bool _looksAnimated(WallpaperItem it) {
    final m = it.mime.toLowerCase();
    return it.animated ||
        m.contains('gif') ||
        m.contains('webp') ||
        m.startsWith('video/');
  }

  bool _hasLiveItems(List<WallpaperItem> items) =>
      items.any(_looksAnimated);

  Future<void> _apply() async {
    final home = WallpaperPlaylist.homeItems.value;
    final lock = WallpaperPlaylist.lockItems.value;
    if (home.isEmpty && lock.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('兩個清單都是空的，先加入圖片')));
      return;
    }
    if (home.isNotEmpty || _hasLiveItems(lock)) {
      await _applyLive();
    } else {
      await _applyStatic();
    }
  }

  Future<void> _applyLockOnly() async {
    final messenger = ScaffoldMessenger.of(context);
    final s = WallpaperPlaylist.settings.value;
    final lock = WallpaperPlaylist.lockItems.value;
    if (lock.isEmpty) return;
    try {
      final lockPaths = await _resolvePaths(lock, WallpaperTarget.lock);
      if (lockPaths.isEmpty) return;
      await NativeWallpaper.applyRotation(
        homePaths: const [],
        lockPaths: lockPaths,
        intervalMinutes: s.intervalMinutes,
        shuffle: s.shuffle,
      );
    } on PlatformException catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('鎖定輪播失敗：${e.message ?? e.code}')));
    }
  }

  static String _extFor(String mime, String path) {
    final m = mime.toLowerCase();
    if (m.contains('mp4')) return 'mp4';
    if (m.contains('quicktime')) return 'mov';
    if (m.contains('m4v')) return 'm4v';
    if (m.contains('webm')) return 'webm';
    if (m.contains('gif')) return 'gif';
    if (m.contains('webp')) return 'webp';
    if (m.contains('png')) return 'png';
    if (m.contains('jpeg') || m.contains('jpg')) return 'jpg';
    final dot = path.lastIndexOf('.');
    if (dot >= 0 && dot < path.length - 1) return path.substring(dot + 1);
    return 'img';
  }

  Future<void> _applyLive() async {
    final messenger = ScaffoldMessenger.of(context);
    final s = WallpaperPlaylist.settings.value;
    final home = WallpaperPlaylist.homeItems.value;
    final lock = WallpaperPlaylist.lockItems.value;
    messenger.showSnackBar(const SnackBar(content: Text('準備中…')));

    Future<List<Map<String, dynamic>>> resolve(
        List<WallpaperItem> source) async {
      final items = <Map<String, dynamic>>[];
      for (final it in source) {
        try {
          final asset = await _asset(it.id);
          if (asset == null) continue;
          var file = await asset.originFile;
          file ??= await asset.file;
          if (file == null) continue;
          items.add({
            'srcPath': file.path,
            'id': it.id,
            'ext': _extFor(it.mime, file.path),
            'animated': _looksAnimated(it),
            'video': asset.type == AssetType.video || it.isVideo,
            // Each item carries its ordered window framings; the native engine
            // expands them into a swipeable/timed sub-sequence.
            'windows': it.windows
                .map((w) => {
                      'zoom': w.zoom,
                      'focusX': w.focusX,
                      'focusY': w.focusY,
                    })
                .toList(),
          });
        } catch (_) {}
      }
      return items;
    }

    final homeItems = await resolve(home);
    final lockItems = await resolve(lock);
    if (homeItems.isEmpty && lockItems.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('找不到可用的圖片檔')));
      return;
    }
    try {
      final secs = s.liveSeconds <= 0 ? 30 : s.liveSeconds;
      await NativeWallpaper.applyLive(
        homeItems: homeItems,
        lockItems: lockItems,
        liveSeconds: secs,
        loops: s.loopsBeforeNext,
        shuffle: s.shuffle,
      );
      await NativeWallpaper.openLiveWallpaperPreview();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('請在系統預覽按「設定」，並選擇主畫面或主畫面與鎖定畫面；每 $secs 秒換下一項。'),
      ));
    } on PlatformException catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('套用失敗：${e.message ?? e.code}')));
    }
  }

  Future<void> _applyStatic() async {
    final messenger = ScaffoldMessenger.of(context);
    final s = WallpaperPlaylist.settings.value;
    final home = WallpaperPlaylist.homeItems.value;
    final lock = WallpaperPlaylist.lockItems.value;
    if (home.isEmpty && lock.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('兩個清單都是空的，先加入圖片')));
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('套用中…')));
    final homePaths = await _resolvePaths(home, WallpaperTarget.home);
    final lockPaths = await _resolvePaths(lock, WallpaperTarget.lock);
    if (homePaths.isEmpty && lockPaths.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('找不到可用的圖片檔')));
      return;
    }
    try {
      await NativeWallpaper.applyRotation(
        homePaths: homePaths,
        lockPaths: lockPaths,
        intervalMinutes: s.intervalMinutes,
        shuffle: s.shuffle,
      );
      messenger.showSnackBar(SnackBar(
        content: Text(
            '已套用：主畫面 ${homePaths.length} 張、鎖定 ${lockPaths.length} 張，約每 ${_intervalText(s.intervalMinutes)}換一張'),
      ));
    } on PlatformException catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('套用失敗：${e.message ?? e.code}')));
    }
  }

  Future<void> _stop() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await NativeWallpaper.cancelRotation();
      messenger.showSnackBar(const SnackBar(
        content: Text('已停止靜態輪播排程。若主畫面是動態桌布，請到系統「桌布」改回別張。'),
      ));
    } on PlatformException catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('停止失敗：${e.message ?? e.code}')));
    }
  }

  static String _intervalText(int minutes) {
    if (minutes >= 1440) return '${minutes ~/ 1440} 天';
    if (minutes >= 60) return '${minutes ~/ 60} 小時';
    return '$minutes 分鐘';
  }

  Future<void> _confirmClear() async {
    final label = _tab.label;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清空「$label」清單'),
        content: Text('確定要移除「$label」清單裡的所有項目嗎？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) await WallpaperPlaylist.clear(_tab);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('輪播桌布'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '設定',
            onPressed: _openSettings,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'clear') _confirmClear();
              if (v == 'diagnostics') _openDiagnostics();
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'clear', child: Text('清空「${_tab.label}」清單')),
              const PopupMenuItem(value: 'diagnostics', child: Text('播放診斷')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Text(
              '圖片與影片可混合輪播。套用後會開系統「動態桌布」預覽，請按設定並選擇主畫面或主畫面與鎖定畫面。'
              '圖片與影片預設完整置中顯示，不會裁掉內容。',
              style: TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: SegmentedButton<WallpaperTarget>(
              segments: const [
                ButtonSegment(
                  value: WallpaperTarget.home,
                  label: Text('主畫面'),
                  icon: Icon(Icons.home_outlined),
                ),
                ButtonSegment(
                  value: WallpaperTarget.lock,
                  label: Text('鎖定'),
                  icon: Icon(Icons.lock_outline),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (sel) => setState(() => _tab = sel.first),
            ),
          ),
          Expanded(child: _list(_tab)),
          const Divider(height: 1),
          const _IntervalBar(),
          _ActionBar(onApply: _apply, onStop: _stop),
        ],
      ),
    );
  }

  Widget _list(WallpaperTarget target) {
    return ValueListenableBuilder<List<WallpaperItem>>(
      valueListenable: WallpaperPlaylist.listFor(target),
      builder: (context, list, _) {
        if (list.isEmpty) return _EmptyState(target: target);
        return ReorderableListView.builder(
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: list.length,
          onReorder: (o, n) => WallpaperPlaylist.reorder(target, o, n),
          itemBuilder: (context, i) {
            final item = list[i];
            return _PlaylistTile(
              key: ValueKey('${target.key}_${item.id}'),
              index: i,
              item: item,
              assetFuture: _asset(item.id),
              onOpen: () => _openCrop(target, item),
              onRemove: () => WallpaperPlaylist.removeAt(target, i),
            );
          },
        );
      },
    );
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _SettingsSheet(),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.target});
  final WallpaperTarget target;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wallpaper_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              '「${target.label}」清單是空的。\n在照片長按多選、或在大圖選「加入輪播」把圖片加進來。',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    super.key,
    required this.index,
    required this.item,
    required this.assetFuture,
    required this.onOpen,
    required this.onRemove,
  });

  final int index;
  final WallpaperItem item;
  final Future<AssetEntity?> assetFuture;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      onTap: onOpen,
      leading: SizedBox(
        width: 48,
        height: 48,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: FutureBuilder<AssetEntity?>(
            future: assetFuture,
            builder: (context, snap) {
              final asset = snap.data;
              if (asset == null) {
                return Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.broken_image_outlined, size: 20),
                );
              }
              return PhotoThumb(asset: asset, side: 96, showVideoBadge: false);
            },
          ),
        ),
      ),
      title: FutureBuilder<AssetEntity?>(
        future: assetFuture,
        builder: (context, snap) => Text(
          snap.data?.title ?? item.id,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      subtitle: Text(
        item.isVideo
            ? '影片（完整置中）'
            : item.windowCount > 1
                ? '${item.windowCount} 個視窗序列（可點按編輯）'
                : item.customized
                    ? '已裁切（可點按加視窗）'
                    : '完整置中（可點按裁切／加視窗）',
        style: TextStyle(
          fontSize: 12,
          color: item.customized || item.windowCount > 1 || item.isVideo
              ? Colors.green
              : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.crop),
            tooltip: '預覽／裁切',
            visualDensity: VisualDensity.compact,
            onPressed: onOpen,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '從清單移除',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.only(left: 4, right: 4),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
    );
  }
}

class _IntervalBar extends StatelessWidget {
  const _IntervalBar();

  static const _secs = [10, 15, 30, 60, 120];

  static String _label(int sec) =>
      sec < 60 ? '$sec 秒' : '${sec ~/ 60} 分鐘';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WallpaperSettings>(
      valueListenable: WallpaperPlaylist.settings,
      builder: (context, s, _) {
        final current = s.liveSeconds <= 0 ? 30 : s.liveSeconds;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '每個項目播多久換下一個（現在 ${_label(current)}；改完要再按套用）',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final sec in _secs)
                    ChoiceChip(
                      label: Text(_label(sec)),
                      selected: current == sec,
                      onSelected: (_) => WallpaperPlaylist.updateSettings(
                        s.copyWith(liveSeconds: sec),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.onApply, required this.onStop});
  final VoidCallback onApply;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('套用輪播'),
                onPressed: onApply,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: onStop,
              child: const Text('停止輪播'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late WallpaperSettings _s;

  static const _intervals = <int, String>{
    15: '約 15 分鐘',
    60: '1 小時',
    360: '6 小時',
    1440: '每天',
  };

  @override
  void initState() {
    super.initState();
    _s = WallpaperPlaylist.settings.value.copyWith();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('輪播設定',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            const Text('鎖定畫面靜態輪播間隔（最短約 15 分鐘）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final e in _intervals.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: _s.intervalMinutes == e.key,
                    onSelected: (_) => setState(
                        () => _s = _s.copyWith(intervalMinutes: e.key)),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('隨機順序'),
              value: _s.shuffle,
              onChanged: (v) => setState(() => _s = _s.copyWith(shuffle: v)),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                await WallpaperPlaylist.updateSettings(_s);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }
}

