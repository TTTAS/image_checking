import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:share_plus/share_plus.dart';

import 'collections.dart';

/// Central place for the photo operations that touch the system gallery.
class PhotoActions {
  /// Deletes the given assets. On Android 11+ the system shows its own
  /// confirmation dialog. Returns the ids actually deleted.
  static Future<List<String>> delete(List<AssetEntity> assets) async {
    final ids = assets.map((e) => e.id).toList();
    final deleted = await PhotoManager.editor.deleteWithIds(ids);
    if (deleted.isNotEmpty) {
      await AppCollections.forget(deleted);
    }
    return deleted;
  }

  /// Shares one or more photos through the system share sheet.
  static Future<void> share(List<AssetEntity> assets) async {
    final files = <XFile>[];
    for (final a in assets) {
      final f = await a.file;
      if (f != null) files.add(XFile(f.path));
    }
    if (files.isNotEmpty) {
      await Share.shareXFiles(files);
    }
  }

  /// Saves an edited image as a NEW file in the "PhotoAlbumEdits" album.
  /// The original is never modified.
  static Future<AssetEntity?> saveEdited(Uint8List bytes) async {
    final name = 'edit_${DateTime.now().millisecondsSinceEpoch}.jpg';
    return PhotoManager.editor.saveImage(
      bytes,
      filename: name,
      relativePath: 'Pictures/PhotoAlbumEdits',
    );
  }

  /// Opens the full image editor (crop / rotate / filters / draw / text).
  /// On completion the result is saved as a new file.
  static Future<void> openEditor(
    BuildContext context,
    AssetEntity asset,
  ) async {
    final file = await asset.file;
    if (file == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => ProImageEditor.file(
          file,
          callbacks: ProImageEditorCallbacks(
            onImageEditingComplete: (bytes) async {
              final saved = await saveEdited(bytes);
              messenger.showSnackBar(
                SnackBar(
                  content: Text(saved != null ? '已儲存到 PhotoAlbumEdits' : '儲存失敗'),
                ),
              );
            },
            onCloseEditor: (mode) => Navigator.of(ctx).pop(),
          ),
        ),
      ),
    );
  }
}
