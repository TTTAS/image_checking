import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import 'native_wallpaper.dart';
import 'wallpaper_crop_page.dart';
import 'wallpaper_playlist.dart';
import 'widgets.dart';

/// Manages the two wallpaper playlists (home / lock): reorder, remove, crop each
/// entry, tweak the shared interval / shuffle, and apply or stop the rotation.
///
/// Each side is cropped and rotated independently: the home list writes
/// FLAG_SYSTEM, the lock list writes FLAG_LOCK. Apply uses each entry's cropped
/// file (an un-cropped entry is center-cropped once at apply time and stored).
class WallpaperPage extends StatefulWidget {
  const WallpaperPage({super.key, this.initialTarget = WallpaperTarget.home});

  final WallpaperTarget initialTarget;

  @override
  State<WallpaperPage> createState() => _WallpaperPageState();
}

class _WallpaperPageState extends State<WallpaperPage> {
  final Map<String, Future<AssetEntity?>> _assetCache = {};
  late WallpaperTarget _tab = widget.initialTarget;

  Future<AssetEntity?> _asset(String id) =>
      _assetCache[id] ??= AssetEntity.fromId(id);

  Future<void> _openCrop(WallpaperTarget target, WallpaperItem item) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final asset = await _asset(item.id);
    if (asset == null) {
      messenger.showSnackBar(const SnackBar(content: Text('找不到原始圖片')));
      return;
    }
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => WallpaperCropPage(
        asset: asset,
        target: target,
        initialZoom: item.cropZoom,
        initialFocusX: item.cropFocusX,
        initialFocusY: item.cropFocusY,
      ),
    ));
  }

  /// Resolves a list to its cropped-file paths. Entries without a crop yet are
  /// center-cropped once (native) and the resulting file is stored, so rotation
  /// always uses a real cropped file — never an on-the-fly crop of the original.
  Future<List<String>> _resolvePaths(
      List<WallpaperItem> items, WallpaperTarget t) async {
    final paths = <String>[];
    for (final it in items) {
      if (it.filePath.isNotEmpty) {
        paths.add(it.filePath);
        continue;
      }
      try {
        final asset = await _asset(it.id);
        final file = await asset?.file;
        if (file == null) continue;
        final path =
            await NativeWallpaper.centerCropSave(file.path, t.key, it.id);
        await WallpaperPlaylist.setCropped(t, it.id, path);
        paths.add(path);
      } catch (_) {
        // skip broken / deleted
      }
    }
    return paths;
  }

  Future<void> _apply() async {
    if (WallpaperPlaylist.settings.value.live) {
      await _applyLive();
    } else {
      await _applyStatic();
    }
  }

  static String _extFor(String mime, String path) {
    final m = mime.toLowerCase();
    if (m.contains('gif')) return 'gif';
    if (m.contains('webp')) return 'webp';
    if (m.contains('png')) return 'png';
    if (m.contains('jpeg') || m.contains('jpg')) return 'jpg';
    final dot = path.lastIndexOf('.');
    if (dot >= 0 && dot < path.length - 1) return path.substring(dot + 1);
    return 'img';
  }

  /// Dynamic (Live) apply: plays the HOME list. Copies each original (keeping
  /// animation) via native, then opens the system live-wallpaper preview for the
  /// user to confirm. Uses each entry's saved crop transform (no jpg source).
  Future<void> _applyLive() async {
    final messenger = ScaffoldMessenger.of(context);
    final s = WallpaperPlaylist.settings.value;
    final home = WallpaperPlaylist.homeItems.value;
    if (home.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('主畫面清單是空的（動態桌布播主畫面清單）')));
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('準備中…')));
    final items = <Map<String, dynamic>>[];
    for (final it in home) {
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
          'zoom': it.cropZoom,
          'focusX': it.cropFocusX,
          'focusY': it.cropFocusY,
          'animated': it.animated,
        });
      } catch (_) {
        // skip broken / deleted
      }
    }
    if (items.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('找不到可用的圖片檔（可能已被刪除）')));
      return;
    }
    try {
      await NativeWallpaper.applyLive(
        items: items,
        liveSeconds: s.liveSeconds,
        loops: s.loopsBeforeNext,
        shuffle: s.shuffle,
      );
      await NativeWallpaper.openLiveWallpaperPreview();
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('已準備動態桌布，請在系統預覽按「設定」套用。'),
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
          const SnackBar(content: Text('找不到可用的圖片檔（可能已被刪除）')));
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
    final live = WallpaperPlaylist.settings.value.live;
    try {
      await NativeWallpaper.cancelRotation();
      messenger.showSnackBar(SnackBar(
        content: Text(live
            ? '已停止靜態輪播排程。動態桌布無法由 App 移除，請到系統「桌布」設定改回別的桌布。'
            : '已停止輪播。目前桌布會保留，只是不再自動更換。'),
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
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'clear', child: Text('清空「${_tab.label}」清單')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          ValueListenableBuilder<WallpaperSettings>(
            valueListenable: WallpaperPlaylist.settings,
            builder: (context, s, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('靜態'),
                        icon: Icon(Icons.image_outlined),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text('動態'),
                        icon: Icon(Icons.gif_box_outlined),
                      ),
                    ],
                    selected: {s.live},
                    onSelectionChanged: (sel) => WallpaperPlaylist.updateSettings(
                        s.copyWith(live: sel.first)),
                  ),
                ),
                if (s.live)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 0, 12, 4),
                    child: Text(
                      '動態：播「主畫面」清單的 GIF／動態 WebP。必須在系統預覽按「設定」才生效；'
                      '鎖定畫面不保證會動、較耗電；之後要改回請到系統桌布設定（App 無法自行移除動態桌布）。',
                      style: TextStyle(fontSize: 11.5, color: Colors.deepOrange),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
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
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Text(
              '主畫面／鎖定各自獨立：分別裁切、分別輪播。每張都用你裁好的畫面。',
              style: TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(child: _list(_tab)),
          const Divider(height: 1),
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

/// One reorderable row: thumbnail + filename + crop-state + crop / delete / drag.
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
        item.cropped ? '已裁切' : '未裁切（套用時會自動置中裁切）',
        style: TextStyle(
          fontSize: 12,
          color: item.cropped ? Colors.green : null,
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

/// Bottom apply / stop buttons.
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

/// Shared settings: interval + shuffle only (scope is now decided by the list).
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
            if (!_s.live) ...[
              const Text('切換間隔（靜態，主畫面與鎖定共用）',
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
            ] else ...[
              const Text('每張播放秒數（動態；0＝改用圈數）',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final sec in const [0, 5, 15, 30, 60])
                    ChoiceChip(
                      label: Text(sec == 0 ? '用圈數' : '$sec 秒'),
                      selected: _s.liveSeconds == sec,
                      onSelected: (_) =>
                          setState(() => _s = _s.copyWith(liveSeconds: sec)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('播完幾圈換（動態；秒數為 0 時生效）',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final n in const [1, 2, 3, 5])
                    ChoiceChip(
                      label: Text('$n 圈'),
                      selected: _s.loopsBeforeNext == n,
                      onSelected: (_) =>
                          setState(() => _s = _s.copyWith(loopsBeforeNext: n)),
                    ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('秒數優先：有設秒數就以秒為準，否則用圈數。',
                    style: TextStyle(fontSize: 11)),
              ),
            ],
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
