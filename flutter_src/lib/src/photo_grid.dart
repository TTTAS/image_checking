import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'add_to_album.dart';
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
///
/// When [onRemoveFromAlbum] is supplied (virtual-album detail), an extra
/// "移出相簿" action appears that drops the selection from that album without
/// touching the files.
AppBar selectionAppBar({
  required SelectionController selection,
  required List<AssetEntity> all,
  Future<void> Function()? reload,
  Future<void> Function(List<AssetEntity> assets)? onRemoveFromAlbum,
}) {
  List<AssetEntity> selected() =>
      all.where((a) => selection.ids.contains(a.id)).toList();

  return AppBar(
    leading: IconButton(
      icon: const Icon(Icons.close),
      onPressed: selection.clear,
    ),
    title: Text('已選 ${selection.count}'),
    // Most-used actions stay as icons; the rest live in the "⋯" overflow menu
    // so the bar never overflows on narrow screens.
    actions: [
      IconButton(
        icon: const Icon(Icons.favorite_border),
        tooltip: '加入最愛',
        onPressed: () async {
          await AppCollections.setFavorite(selection.ids, true);
          selection.clear();
        },
      ),
      Builder(
        builder: (context) => IconButton(
          icon: const Icon(Icons.add_to_photos_outlined),
          tooltip: '加入相簿',
          onPressed: () async {
            await showAddToAlbumSheet(context, selection.ids.toList());
            selection.clear();
          },
        ),
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
        icon: const Icon(Icons.delete_outline),
        tooltip: '刪除',
        onPressed: () async {
          final deleted = await PhotoActions.delete(selected());
          selection.clear();
          PhotoLibrary.instance.removeIds(deleted);
          if (reload != null && deleted.isNotEmpty) await reload();
        },
      ),
      Builder(
        builder: (context) => PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: '更多',
          onSelected: (v) async {
            final messenger = ScaffoldMessenger.of(context);
            final navigator = Navigator.of(context);
            final chosen = selected();
            if (v == 'share') {
              await PhotoActions.share(chosen);
            } else if (v == 'remove') {
              selection.clear();
              if (onRemoveFromAlbum != null) {
                await onRemoveFromAlbum(chosen);
              }
            } else {
              // Wallpaper playlist: 'wp_home' / 'wp_lock' / 'wp_both'.
              final targets = v == 'wp_both'
                  ? [WallpaperTarget.home, WallpaperTarget.lock]
                  : [
                      v == 'wp_lock'
                          ? WallpaperTarget.lock
                          : WallpaperTarget.home
                    ];
              var added = 0;
              for (final t in targets) {
                added += await WallpaperPlaylist.addAll(chosen, t);
              }
              selection.clear();
              final label =
                  targets.length >= 2 ? '主畫面與鎖定' : targets.first.label;
              messenger.showSnackBar(SnackBar(
                content: Text(added > 0
                    ? '已加入 $added 筆到$label輪播'
                    : '沒有可加入的圖片或影片（格式不支援或已在清單中）'),
                action: added > 0
                    ? SnackBarAction(
                        label: '檢視',
                        onPressed: () => navigator.push(
                          MaterialPageRoute<void>(
                              builder: (_) => WallpaperPage(
                                  initialTarget: targets.first)),
                        ),
                      )
                    : null,
              ));
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'share',
              child: _MenuRow(icon: Icons.share_outlined, label: '分享'),
            ),
            if (onRemoveFromAlbum != null)
              const PopupMenuItem(
                value: 'remove',
                child: _MenuRow(
                    icon: Icons.remove_circle_outline, label: '移出相簿'),
              ),
            const PopupMenuItem(
              value: 'wp_home',
              child: _MenuRow(icon: Icons.slideshow_outlined, label: '加入主畫面輪播'),
            ),
            const PopupMenuItem(
              value: 'wp_lock',
              child: _MenuRow(icon: Icons.slideshow_outlined, label: '加入鎖定輪播'),
            ),
            const PopupMenuItem(
              value: 'wp_both',
              child: _MenuRow(icon: Icons.slideshow_outlined, label: '兩邊都加入輪播'),
            ),
          ],
        ),
      ),
    ],
  );
}

/// A compact icon + label row for the selection bar's overflow menu.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}
