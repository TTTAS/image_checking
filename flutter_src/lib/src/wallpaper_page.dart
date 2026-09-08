import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'wallpaper_playlist.dart';
import 'widgets.dart';

/// Manages the wallpaper playlist: reorder / remove entries, tweak rotation
/// settings, and (from M2 on) apply or stop the rotation.
///
/// Milestone M1: the list and settings are fully functional and persisted;
/// "apply" / "stop" are placeholders that explain the rotation itself lands in
/// the next version. Nothing here touches the native side or the build.
class WallpaperPage extends StatefulWidget {
  const WallpaperPage({super.key});

  @override
  State<WallpaperPage> createState() => _WallpaperPageState();
}

class _WallpaperPageState extends State<WallpaperPage> {
  // Cache the id -> asset lookups so reordering / rebuilding doesn't refetch
  // (and flicker) every thumbnail.
  final Map<String, Future<AssetEntity?>> _assetCache = {};

  Future<AssetEntity?> _asset(String id) =>
      _assetCache[id] ??= AssetEntity.fromId(id);

  void _notImplemented(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$what」會在下一版（靜態輪播）提供')),
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空輪播清單'),
        content: const Text('確定要移除清單裡的所有項目嗎？'),
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
    if (ok == true) await WallpaperPlaylist.clear();
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
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'clear', child: Text('清空清單')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _ModeSelector(),
          Expanded(
            child: ValueListenableBuilder<List<WallpaperItem>>(
              valueListenable: WallpaperPlaylist.items,
              builder: (context, list, _) {
                if (list.isEmpty) return const _EmptyState();
                return ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: list.length,
                  onReorder: WallpaperPlaylist.reorder,
                  itemBuilder: (context, i) {
                    final item = list[i];
                    return _PlaylistTile(
                      key: ValueKey(item.id),
                      index: i,
                      item: item,
                      assetFuture: _asset(item.id),
                      onRemove: () => WallpaperPlaylist.removeAt(i),
                    );
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          _ActionBar(
            onApply: () => _notImplemented('套用輪播'),
            onStop: () => _notImplemented('停止輪播'),
          ),
        ],
      ),
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

/// The static / live mode toggle, plus the live-mode caveat banner.
class _ModeSelector extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WallpaperSettings>(
      valueListenable: WallpaperPlaylist.settings,
      builder: (context, s, _) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('靜態輪播'),
                    icon: Icon(Icons.image_outlined),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('動態'),
                    icon: Icon(Icons.gif_box_outlined),
                  ),
                ],
                selected: {s.live},
                onSelectionChanged: (sel) =>
                    WallpaperPlaylist.updateSettings(s.copyWith(live: sel.first)),
              ),
            ),
            if (s.live)
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: _InfoBanner(
                  '動態桌布必須在系統預覽按「設定」才會套用；部分手機鎖定畫面不會動，也比靜態更耗電。',
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: _InfoBanner(
                  '靜態輪播只會顯示一張圖（GIF／動態 WebP 只顯示第一幀、不會動），約每 15 分鐘以上換一張。',
                ),
              ),
          ],
        );
      },
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.wallpaper_outlined, size: 48),
            SizedBox(height: 16),
            Text(
              '清單是空的。\n在照片長按多選、或在大圖選「加入輪播清單」把圖片加進來。',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// One reorderable row: thumbnail + filename + animated badge + delete.
class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    super.key,
    required this.index,
    required this.item,
    required this.assetFuture,
    required this.onRemove,
  });

  final int index;
  final WallpaperItem item;
  final Future<AssetEntity?> assetFuture;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
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
        item.animated
            ? 'GIF（動態，需動態模式才會播）'
            : (item.mime == 'image/webp' ? 'WebP' : item.mime),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '從清單移除',
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

/// Editable settings, shown in a bottom sheet. Edits a working copy and saves on
/// "完成".
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

  int get _scope => _s.flags;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('輪播設定',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),

            // Static-mode interval.
            if (!_s.live) ...[
              const _SectionLabel('切換間隔（靜態）'),
              Wrap(
                spacing: 8,
                children: [
                  for (final e in _intervals.entries)
                    ChoiceChip(
                      label: Text(e.value),
                      selected: _s.intervalMinutes == e.key,
                      onSelected: (_) =>
                          setState(() => _s = _s.copyWith(intervalMinutes: e.key)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],

            // Live-mode timing.
            if (_s.live) ...[
              const _SectionLabel('切換方式（動態）'),
              const Text(
                '有填秒數就以秒為準，否則播完設定的圈數再換。',
                style: TextStyle(fontSize: 12),
              ),
              Row(
                children: [
                  Expanded(
                    child: _NumberField(
                      label: '固定秒數（0 = 不用）',
                      value: _s.liveSeconds,
                      min: 0,
                      max: 3600,
                      onChanged: (v) =>
                          setState(() => _s = _s.copyWith(liveSeconds: v)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _NumberField(
                      label: '播完幾圈換',
                      value: _s.loopsBeforeNext,
                      min: 1,
                      max: 100,
                      onChanged: (v) =>
                          setState(() => _s = _s.copyWith(loopsBeforeNext: v)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],

            // Static-mode apply scope.
            if (!_s.live) ...[
              const _SectionLabel('套用範圍（靜態）'),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                      value: WallpaperSettings.flagSystem, label: Text('主畫面')),
                  ButtonSegment(
                      value: WallpaperSettings.flagLock, label: Text('鎖定')),
                  ButtonSegment(
                      value: WallpaperSettings.flagSystem |
                          WallpaperSettings.flagLock,
                      label: Text('兩者')),
                ],
                selected: {_scope},
                onSelectionChanged: (sel) =>
                    setState(() => _s = _s.copyWith(flags: sel.first)),
              ),
              const SizedBox(height: 12),
            ],

            // Fit (contain disabled until M4).
            const _SectionLabel('縮放'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'crop', label: Text('裁切填滿')),
                ButtonSegment(
                    value: 'contain',
                    label: Text('完整顯示'),
                    enabled: false),
              ],
              selected: {_s.fit == 'contain' ? 'contain' : 'crop'},
              onSelectionChanged: (sel) =>
                  setState(() => _s = _s.copyWith(fit: sel.first)),
            ),
            const Text(
              '「完整顯示＋底色」將於後續版本提供。',
              style: TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 8),

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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Text(text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

/// A tiny stepper-style integer field.
class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed:
                  value > min ? () => onChanged((value - 1).clamp(min, max)) : null,
            ),
            Text('$value', style: const TextStyle(fontSize: 16)),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed:
                  value < max ? () => onChanged((value + 1).clamp(min, max)) : null,
            ),
          ],
        ),
      ],
    );
  }
}
