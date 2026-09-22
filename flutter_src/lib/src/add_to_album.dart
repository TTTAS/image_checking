import 'package:flutter/material.dart';

import 'virtual_albums.dart';

/// Small dialog that asks for an album name. Returns the trimmed name, or null
/// if cancelled / left empty. Reused by "create album" and "rename album".
Future<String?> promptAlbumName(
  BuildContext context, {
  String? initial,
  String title = '新增相簿',
}) async {
  final controller = TextEditingController(text: initial ?? '');
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '輸入相簿名稱'),
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('確定'),
        ),
      ],
    ),
  );
  final trimmed = name?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

/// Bottom sheet that lets the user drop the given [assetIds] into one or more
/// virtual albums (tag-like: a photo can be in several at once). Also offers a
/// "建立新相簿" shortcut. Purely app-local — no files are moved.
Future<void> showAddToAlbumSheet(
  BuildContext context,
  Iterable<String> assetIds,
) async {
  final ids = assetIds.toList();
  if (ids.isEmpty) return;

  final chosen = <String>{};
  final messenger = ScaffoldMessenger.of(context);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetCtx) {
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          final albums = VirtualAlbums.albums.value;
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Text(
                      '加入相簿（${ids.length} 張）',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.add),
                          title: const Text('建立新相簿'),
                          onTap: () async {
                            final name = await promptAlbumName(ctx);
                            if (name == null) return;
                            final id = await VirtualAlbums.create(name);
                            setSheet(() => chosen.add(id));
                          },
                        ),
                        if (albums.isNotEmpty) const Divider(height: 1),
                        for (final a in albums)
                          CheckboxListTile(
                            value: chosen.contains(a.id),
                            title: Text(
                              a.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('${a.count} 張'),
                            onChanged: (on) => setSheet(() {
                              if (on ?? false) {
                                chosen.add(a.id);
                              } else {
                                chosen.remove(a.id);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: FilledButton(
                      onPressed: chosen.isEmpty
                          ? null
                          : () => Navigator.of(ctx).pop(),
                      child: Text(chosen.isEmpty
                          ? '選擇相簿'
                          : '加入 ${chosen.length} 個相簿'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );

  if (chosen.isEmpty) return;
  var total = 0;
  for (final albumId in chosen) {
    total += await VirtualAlbums.addAssets(albumId, ids);
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(total > 0
          ? '已加入 $total 張到 ${chosen.length} 個相簿'
          : '這些照片已在所選相簿中'),
    ),
  );
}
