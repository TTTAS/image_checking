import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'collections.dart';
import 'library.dart';
import 'photo_actions.dart';
import 'selection.dart';
import 'wallpaper_page.dart';
import 'wallpaper_playlist.dart';
import 'widgets.dart';

/// One thumbnail that supports tap-to-open, long-press-to-select, and shows
/// favorite / selection overlays. Rebuilds when selection or favorites change.
class SelectableThumb extends StatelessWidget {
  const SelectableThumb({
    super.key,
    required this.assets,
    required this.index,
    required this.selection,
    required this.onOpen,
  });

  final List<AssetEntity> assets;
  final int index;
  final SelectionController selection;

  /// Called when the tile is tapped while NOT in selection mode.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final asset = assets[index];
    final id = asset.id;
    return AnimatedBuilder(
      animation: Listenable.merge([selection, AppCollections.favorites]),
      builder: (context, _) {
        final selected = selection.isSelected(id);
        return GestureDetector(
          onTap: selection.active ? () => selection.toggle(id) : onOpen,
          onLongPress: () => selection.enter(id),
          child: Stack(
            fit: StackFit.expand,
            children: [
              PhotoThumb(asset: asset),
              if (AppCollections.isFavorite(id))
                const Positioned(
                  left: 4,
                  bottom: 4,
                  child: Icon(Icons.favorite, size: 16, color: Colors.redAccent),
                ),
              if (selection.active)
                Container(
                  color: selected
                      ? Colors.black.withValues(alpha: 0.35)
                      : Colors.transparent,
                  alignment: Alignment.topRight,
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The AppBar shown while in multi-select mode: favorite / hide / share /
/// delete acting on the current selection.
/// [reload] is only needed by folder-scoped grids (folder detail) that keep
/// their own asset list; the home tabs read the shared [PhotoLibrary] and pass
/// nothing, since hiding flows through [AppCollections] and deletion through
/// [PhotoLibrary.removeIds].
AppBar selectionAppBar({
  required SelectionController selection,
  required List<AssetEntity> all,
  Future<void> Function()? reload,
}) {
  List<AssetEntity> selected() =>
      all.where((a) => selection.ids.contains(a.id)).toList();

  return AppBar(
    leading: IconButton(
      icon: const Icon(Icons.close),
      onPressed: selection.clear,
    ),
    title: Text('已選 ${selection.count}'),
    actions: [
      IconButton(
        icon: const Icon(Icons.favorite_border),
        tooltip: '加入最愛',
        onPressed: () async {
          await AppCollections.setFavorite(selection.ids, true);
          selection.clear();
        },
      ),
      IconButton(
        icon: const Icon(Icons.visibility_off_outlined),
        tooltip: '隱藏',
        onPressed: () async {
          await AppCollections.setHidden(selection.ids, true);
          selection.clear();
          if (reload != null) await reload();
        },
      ),
      IconButton(
        icon: const Icon(Icons.share_outlined),
        tooltip: '分享',
        onPressed: () => PhotoActions.share(selected()),
      ),
      Builder(
        builder: (context) => PopupMenuButton<String>(
          icon: const Icon(Icons.slideshow_outlined),
          tooltip: '加入輪播',
          onSelected: (v) async {
            final targets = v == 'both'
                ? [WallpaperTarget.home, WallpaperTarget.lock]
                : [v == 'lock' ? WallpaperTarget.lock : WallpaperTarget.home];
            final messenger = ScaffoldMessenger.of(context);
            final navigator = Navigator.of(context);
            final chosen = selected();
            var added = 0;
            final addedByTarget = <WallpaperTarget, int>{};
            for (final t in targets) {
              final count = await WallpaperPlaylist.addAll(chosen, t);
              addedByTarget[t] = count;
              added += count;
            }
            selection.clear();
            final label = targets.length >= 2 ? '主畫面與鎖定' : targets.first.label;
            final hasVideo = chosen.any((a) => a.type == AssetType.video);
            final String message;
            if (targets.length >= 2 && added > 0) {
              message =
                  '已加入主畫面 ${addedByTarget[WallpaperTarget.home] ?? 0} 筆、'
                  '鎖定 ${addedByTarget[WallpaperTarget.lock] ?? 0} 張'
                  '${hasVideo ? '（影片只加入主畫面）' : ''}';
            } else if (added > 0) {
              message = '已加入 $added 筆到$label輪播';
            } else if (targets.length == 1 &&
                targets.first == WallpaperTarget.lock &&
                hasVideo) {
              message = '影片只能加入主畫面輪播；圖片可能已在清單中';
            } else {
              message = '沒有可加入的素材（格式不支援或已在清單中）';
            }
            messenger.showSnackBar(SnackBar(
              content: Text(message),
              action: added > 0
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
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'home', child: Text('加入主畫面輪播')),
            PopupMenuItem(value: 'lock', child: Text('加入鎖定輪播')),
            PopupMenuItem(value: 'both', child: Text('兩邊都加入輪播')),
          ],
        ),
      ),
      IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: '刪除',
        onPressed: () async {
          final deleted = await PhotoActions.delete(selected());
          selection.clear();
          PhotoLibrary.instance.removeIds(deleted);
          if (reload != null && deleted.isNotEmpty) await reload();
        },
      ),
    ],
  );
}
