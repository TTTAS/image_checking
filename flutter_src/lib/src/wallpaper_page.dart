import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import 'native_wallpaper.dart';
import 'wallpaper_crop_page.dart';
import 'wallpaper_playlist.dart';
import 'widgets.dart';

class WallpaperPage extends StatefulWidget {
  const WallpaperPage({super.key, this.initialTarget = WallpaperTarget.home});

  final WallpaperTarget initialTarget;

  @override
  State<WallpaperPage> createState() => _WallpaperPageState();
}

class _WallpaperPageState extends State<WallpaperPage> {
  final Map<String, Future<AssetEntity?>> _assetCache = {};
  late WallpaperTarget _tab = widget.initialTarget;
  bool _applying = false;

  Future<AssetEntity?> _asset(String id) =>
      _assetCache[id] ??= AssetEntity.fromId(id);

  Future<void> _openCrop(WallpaperTarget target, WallpaperItem item) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final asset = await _asset(item.id);
    if (asset == null) {
      messenger.showSnackBar(const SnackBar(content: Text('找不到原始素材')));
      return;
    }
    if (!mounted) return;
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

  static String _extFor(String mime, String path) {
    final m = mime.toLowerCase();
    if (m.contains('gif')) return 'gif';
    if (m.contains('webp')) return 'webp';
    if (m.contains('png')) return 'png';
    if (m.contains('jpeg')) return 'jpg';
    final dot = path.lastIndexOf('.');
    return dot >= 0 ? path.substring(dot + 1) : 'img';
  }

  Future<void> _apply() async {
    if (_applying) return;
    final target = _tab;
    final list = List<WallpaperItem>.of(WallpaperPlaylist.listFor(target).value);
    final messenger = ScaffoldMessenger.of(context);
    if (list.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text('${target.label}清單是空的，先加入素材')));
      return;
    }
    setState(() => _applying = true);
    try {
      final items = <Map<String, dynamic>>[];
      for (final item in list) {
        final asset = await _asset(item.id);
        final file = await asset?.originFile ?? await asset?.file;
        if (file == null) throw StateError('部分素材無法讀取，請移除遺失項目後重試');
        items.add({
          'srcPath': file.path, 'id': item.id,
          'ext': _extFor(item.mime, file.path),
          'zoom': item.cropZoom, 'focusX': item.cropFocusX, 'focusY': item.cropFocusY,
          'animated': item.animated,
          'type': item.video ? 'video' : (item.animated ? 'animated' : 'still'),
          'mime': item.mime, 'width': item.sourceWidth, 'height': item.sourceHeight,
        });
      }
      final settings = WallpaperPlaylist.settings.value;
      await NativeWallpaper.applyLive(
        side: target.key, items: items,
        liveSeconds: settings.secondsFor(target),
        loops: settings.loopsBeforeNext, shuffle: settings.shuffle,
      );
      if (!mounted) return;
      await NativeWallpaper.openLiveWallpaperPreview(side: target.key);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(
        '請在系統預覽選「${target.label}」。若系統只提供「兩者」，會同時更換兩邊桌布。',
      )));
    } catch (e) {
      if (mounted) {
        final message = e is PlatformException ? (e.message ?? e.code) : '$e';
        messenger.showSnackBar(SnackBar(content: Text('套用失敗：$message')));
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _stop() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await NativeWallpaper.cancelRotation();
      messenger.showSnackBar(const SnackBar(
        content: Text('已停止舊版靜態輪播排程。主畫面或鎖定畫面使用動態桌布時，請到系統「桌布」改回別張。'),
      ));
    } on PlatformException catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('停止失敗：${e.message ?? e.code}')));
    }
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
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Text(
              '主畫面、鎖定清單都可混合圖片、GIF 與影片，點選素材可裁切，影片靜音播放。'
              '套用只更新目前分頁，請在系統預覽選擇對應畫面；若系統只提供「兩者」，會同時更換兩邊桌布。',
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
              onSelectionChanged: _applying ? null : (sel) => setState(() => _tab = sel.first),
            ),
          ),
          Expanded(child: _list(_tab)),
          const Divider(height: 1),
          _IntervalBar(target: _tab),
          _ActionBar(label: '套用${_tab.label}輪播', onApply: _applying ? null : _apply, onStop: _stop),
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
    showWallpaperSettings(context);
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
              '「${target.label}」清單是空的。\n'
              '在相簿長按多選，或從大圖加入圖片與影片。',
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
              return PhotoThumb(asset: asset, side: 96, showVideoBadge: true);
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
      subtitle: item.video
          ? FutureBuilder<AssetEntity?>(
              future: assetFuture,
              builder: (context, snap) {
                final duration = snap.data?.videoDuration ?? Duration.zero;
                final minutes = duration.inMinutes;
                final seconds = duration.inSeconds.remainder(60);
                final time = '$minutes:${seconds.toString().padLeft(2, '0')}';
                return Text('影片・$time・${item.cropped ? '已裁切' : '完整置中'}',
                    style: const TextStyle(fontSize: 12));
              },
            )
          : Text(
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

class _IntervalBar extends StatelessWidget {
  const _IntervalBar({required this.target});
  final WallpaperTarget target;

  static const _secs = [10, 15, 30, 60, 120];

  static String _label(int sec) =>
      sec < 60 ? '$sec 秒' : '${sec ~/ 60} 分鐘';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WallpaperSettings>(
      valueListenable: WallpaperPlaylist.settings,
      builder: (context, s, _) {
        final current = s.secondsFor(target) <= 0 ? 30 : s.secondsFor(target);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${target.label}每項播多久換下一項（現在 ${_label(current)}；改完要再按套用）',
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
                        target == WallpaperTarget.home
                            ? s.copyWith(liveSeconds: sec)
                            : s.copyWith(lockLiveSeconds: sec),
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
  const _ActionBar({required this.label, required this.onApply, required this.onStop});
  final String label;
  final VoidCallback? onApply;
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
                label: Text(label),
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

void showWallpaperSettings(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late WallpaperSettings _s;

  @override
  void initState() {
    super.initState();
    _s = WallpaperPlaylist.settings.value.copyWith();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
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
            for (final target in WallpaperTarget.values) ...[
              Text('${target.label}每項播放時間（圖片、GIF、影片皆適用）'),
              Wrap(spacing: 8, children: [
                for (final sec in [10, 15, 30, 60, 120])
                  ChoiceChip(
                    key: ValueKey('${target.key}_$sec'),
                    label: Text('$sec 秒'),
                    selected: _s.secondsFor(target) == sec,
                    onSelected: (_) => setState(() => _s = target == WallpaperTarget.home
                        ? _s.copyWith(liveSeconds: sec) : _s.copyWith(lockLiveSeconds: sec)),
                  ),
              ]),
              const SizedBox(height: 12),
            ],
            const Text('短影片循環播放，時間到切換下一項；修改後請重新套用對應清單。'),
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
      ),
    );
  }
}
