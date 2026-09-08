import 'package:flutter/services.dart';

/// Bridge to the native (Kotlin) side for wallpaper features.
class NativeWallpaper {
  NativeWallpaper._();

  static const _channel = MethodChannel('photo_album/native');

  /// Opens the system "crop & set wallpaper" screen for the image at [uri]
  /// (a content:// URI), letting the user position/crop and choose which
  /// screen before applying. Throws [PlatformException] on failure.
  static Future<void> setFromUri(String uri) async {
    await _channel.invokeMethod<bool>('setWallpaper', {'uri': uri});
  }

  /// Applies the static rotation (mode A): copies the given source files into
  /// the app's private dir, sets the first one as the wallpaper immediately, and
  /// schedules a periodic background job (WorkManager) to advance to the next
  /// one about every [intervalMinutes] minutes.
  ///
  /// [items] is an ordered list of `{'id', 'path', 'mime', 'animated'}` maps;
  /// [path] is a readable file path (from photo_manager's `AssetEntity.file`).
  /// [flags] is a bitmask (1 = home screen, 2 = lock screen).
  /// Throws [PlatformException] on failure.
  static Future<void> applyStatic({
    required List<Map<String, dynamic>> items,
    required int intervalMinutes,
    required int flags,
    required String fit,
    required bool shuffle,
  }) async {
    await _channel.invokeMethod<bool>('applyStaticWallpaper', {
      'items': items,
      'intervalMinutes': intervalMinutes,
      'flags': flags,
      'fit': fit,
      'shuffle': shuffle,
    });
  }

  /// Cancels the periodic rotation job. The current wallpaper stays as-is; it
  /// just stops changing on its own.
  static Future<void> cancelRotation() async {
    await _channel.invokeMethod<bool>('cancelWallpaperWork');
  }
}
