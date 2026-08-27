import 'package:flutter/services.dart';

/// Bridge to the native (Kotlin) side for operations photo_manager cannot do:
/// requesting "All files access" and renaming a real folder on disk.
class NativeFolder {
  NativeFolder._();

  static const _channel = MethodChannel('photo_album/native');

  /// Whether the app currently holds MANAGE_EXTERNAL_STORAGE (always true
  /// below Android 11).
  static Future<bool> hasAllFilesAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the system "All files access" settings page for this app.
  static Future<void> requestAllFilesAccess() async {
    await _channel.invokeMethod<void>('requestAllFilesAccess');
  }

  /// Renames the folder at [oldPath] to [newName] (same parent directory) and
  /// asks MediaStore to reindex. Returns the new absolute path.
  /// Throws [PlatformException] with a readable message on failure.
  static Future<String> renameFolder(String oldPath, String newName) async {
    final result = await _channel.invokeMethod<String>('renameFolder', {
      'oldPath': oldPath,
      'newName': newName,
    });
    return result ?? '';
  }
}
