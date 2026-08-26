import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'collections.dart';
import 'photo_actions.dart';
import 'selection.dart';
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
AppBar selectionAppBar({
  required SelectionController selection,
  required List<AssetEntity> all,
  required Future<void> Function() reload,
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
          await reload();
        },
      ),
      IconButton(
        icon: const Icon(Icons.share_outlined),
        tooltip: '分享',
        onPressed: () => PhotoActions.share(selected()),
      ),
      IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: '刪除',
        onPressed: () async {
          final deleted = await PhotoActions.delete(selected());
          selection.clear();
          if (deleted.isNotEmpty) await reload();
        },
      ),
    ],
  );
}
