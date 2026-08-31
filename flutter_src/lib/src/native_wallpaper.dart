import 'package:flutter/services.dart';

/// Bridge to the native (Kotlin) side for setting a photo as the wallpaper.
class NativeWallpaper {
  NativeWallpaper._();

  static const _channel = MethodChannel('photo_album/native');

  /// Opens the system "crop & set wallpaper" screen for the image at [uri]
  /// (a content:// URI), letting the user position/crop and choose which
  /// screen before applying. Throws [PlatformException] on failure.
  static Future<void> setFromUri(String uri) async {
    await _channel.invokeMethod<bool>('setWallpaper', {'uri': uri});
  }
}
