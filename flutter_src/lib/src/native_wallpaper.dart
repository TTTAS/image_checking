import 'package:flutter/services.dart';

/// Which screen(s) to apply a wallpaper to.
enum WallpaperTarget { home, lock, both }

extension on WallpaperTarget {
  String get arg => switch (this) {
        WallpaperTarget.home => 'home',
        WallpaperTarget.lock => 'lock',
        WallpaperTarget.both => 'both',
      };
}

/// Bridge to the native (Kotlin) side for setting a photo as the wallpaper.
class NativeWallpaper {
  NativeWallpaper._();

  static const _channel = MethodChannel('photo_album/native');

  /// Sets the image at [path] as the wallpaper on the chosen screen(s).
  /// Throws [PlatformException] with a readable message on failure.
  static Future<void> set(String path, WallpaperTarget target) async {
    await _channel.invokeMethod<bool>('setWallpaper', {
      'path': path,
      'target': target.arg,
    });
  }
}
