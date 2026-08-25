import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'sort.dart';

/// Top-right sort menu shown in an [AppBar].
class SortMenuButton extends StatelessWidget {
  const SortMenuButton({
    super.key,
    required this.current,
    required this.onSelected,
  });

  final SortOption current;
  final ValueChanged<SortOption> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<SortOption>(
      icon: const Icon(Icons.sort),
      tooltip: '排序：${current.label}',
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final choice in kSortChoices)
          PopupMenuItem<SortOption>(
            value: choice,
            child: Row(
              children: [
                Icon(
                  (choice.field == current.field && choice.dir == current.dir)
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text(choice.label),
              ],
            ),
          ),
      ],
    );
  }
}

/// A single square thumbnail for a photo.
class PhotoThumb extends StatelessWidget {
  const PhotoThumb({super.key, required this.asset, this.side = 200});

  final AssetEntity asset;
  final int side;

  @override
  Widget build(BuildContext context) {
    return AssetEntityImage(
      asset,
      isOriginal: false,
      thumbnailSize: ThumbnailSize.square(side),
      thumbnailFormat: ThumbnailFormat.jpeg,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      errorBuilder: (context, error, stack) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.broken_image_outlined, size: 20),
      ),
    );
  }
}

/// Loads byte sizes for a set of assets (needed only for size sorting).
Future<Map<String, int>> loadFileSizes(List<AssetEntity> assets) async {
  final result = <String, int>{};
  for (final a in assets) {
    try {
      final file = await a.file;
      result[a.id] = await file?.length() ?? 0;
    } catch (_) {
      result[a.id] = 0;
    }
  }
  return result;
}
