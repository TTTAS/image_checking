import 'package:flutter/services.dart';

/// Bridge to the native (Kotlin) side for operations photo_manager cannot do:
/// requesting "All files access", renaming a real folder, creating a folder,
/// and moving files into a folder on disk.
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

  /// Public Pictures directory, e.g. /storage/emulated/0/Pictures.
  static Future<String> picturesDir() async {
    final result = await _channel.invokeMethod<String>('picturesDir');
    return result ?? '';
  }

  /// Creates [name] under Pictures (or returns it if it already exists).
  /// Returns the new folder's absolute path.
  static Future<String> createFolder(String name) async {
    final result = await _channel.invokeMethod<String>('createFolder', {
      'name': name,
    });
    return result ?? '';
  }

  /// Moves each file in [srcPaths] into [destDir]. Same-name files get a
  /// numeric suffix. Returns how many files actually landed in [destDir].
  static Future<int> moveFiles(List<String> srcPaths, String destDir) async {
    final result = await _channel.invokeMethod<int>('moveFiles', {
      'srcPaths': srcPaths,
      'destDir': destDir,
    });
    return result ?? 0;
  }
}
