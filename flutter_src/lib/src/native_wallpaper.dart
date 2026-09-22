import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Bridge to the native (Kotlin) side for wallpaper features.
class NativeWallpaper {
  NativeWallpaper._();

  static const _channel = MethodChannel('photo_album/native');

  /// Sets an already-cropped image (PNG bytes, sized to the screen by the in-app
  /// crop page) as the wallpaper for [flags] (1 = home, 2 = lock, 3 = both).
  /// Pure native decode + setBitmap — never opens the system cropper or any
  /// external app. Returns whether the per-screen flags were honored (true on
  /// Android N+; false on older devices that can only set one wallpaper).
  /// Throws [PlatformException] on failure.
  static Future<bool> setWallpaperBytes(Uint8List bytes, int flags) async {
    final honored = await _channel.invokeMethod<bool>('setWallpaperBytes', {
      'bytes': bytes,
      'flags': flags,
    });
    return honored ?? true;
  }

  /// Saves the cropped image (PNG [bytes] from the in-app crop page) as a JPEG in
  /// the app's private dir under [side] ("home"/"lock") keyed by [id]. Returns
  /// the saved file path. Does NOT change the wallpaper.
  static Future<String> saveCrop(Uint8List bytes, String side, String id) async {
    final path = await _channel.invokeMethod<String>('saveCrop', {
      'bytes': bytes,
      'side': side,
      'id': id,
    });
    return path ?? '';
  }

  /// Center-crops an original file at [srcPath] to the screen and saves it under
  /// [side]/[id].jpg. Used at apply time for entries the user never cropped.
  /// Returns the saved file path.
  static Future<String> centerCropSave(
      String srcPath, String side, String id) async {
    final path = await _channel.invokeMethod<String>('centerCropSave', {
      'srcPath': srcPath,
      'side': side,
      'id': id,
    });
    return path ?? '';
  }

  /// Renders an original file at [srcPath] framed by a single crop window
  /// ([zoom]/[focusX]/[focusY]) to a screen-sized JPEG under [side]/[id].jpg.
  /// [zoom] <= 0 means "fit whole image, centered". Used by the static rotation
  /// to pre-render each window of an item. Returns the saved file path.
  static Future<String> renderCropSave(
    String srcPath,
    String side,
    String id, {
    required double zoom,
    required double focusX,
    required double focusY,
  }) async {
    final path = await _channel.invokeMethod<String>('renderCropSave', {
      'srcPath': srcPath,
      'side': side,
      'id': id,
      'zoom': zoom,
      'focusX': focusX,
      'focusY': focusY,
    });
    return path ?? '';
  }

  /// Applies the static rotation for both lists. [homePaths]/[lockPaths] are
  /// ordered cropped-file paths (either may be empty). Sets the first of each
  /// side now and schedules a periodic job to advance about every
  /// [intervalMinutes] minutes. Throws [PlatformException] on failure.
  static Future<void> applyRotation({
    required List<String> homePaths,
    required List<String> lockPaths,
    required int intervalMinutes,
    required bool shuffle,
  }) async {
    await _channel.invokeMethod<bool>('applyRotation', {
      'home': homePaths,
      'lock': lockPaths,
      'intervalMinutes': intervalMinutes,
      'shuffle': shuffle,
    });
  }

  /// Cancels the periodic rotation job. The current wallpaper stays as-is; it
  /// just stops changing on its own.
  static Future<void> cancelRotation() async {
    await _channel.invokeMethod<bool>('cancelWallpaperWork');
  }

  /// Live wallpaper (mode B): copies the given ORIGINAL files into the app's
  /// private dir and writes the live manifest. [items] is an ordered list of
  /// `{'srcPath','id','ext','zoom','focusX','focusY','animated'}` maps.
  /// Does NOT set the wallpaper — call [openLiveWallpaperPreview] after.
  /// Throws [PlatformException] on failure.
  static Future<void> applyLive({
    required List<Map<String, dynamic>> homeItems,
    required List<Map<String, dynamic>> lockItems,
    required int liveSeconds,
    required int loops,
    required bool shuffle,
    required int intervalSeconds,
  }) async {
    await _channel.invokeMethod<int>('applyLive', {
      'homeItems': homeItems,
      'lockItems': lockItems,
      'seconds': liveSeconds,
      'loops': loops,
      'shuffle': shuffle,
      'intervalSeconds': intervalSeconds,
    });
  }

  static Future<String> liveWallpaperDiagnostics() async {
    return await _channel.invokeMethod<String>('liveWallpaperDiagnostics') ?? '';
  }

  static Future<String> liveWallpaperError() async {
    return await _channel.invokeMethod<String>('liveWallpaperError') ?? '';
  }

  /// Opens the system "choose live wallpaper" preview for our service. The user
  /// must confirm there (the app cannot set a live wallpaper silently).
  static Future<void> openLiveWallpaperPreview() async {
    await _channel.invokeMethod<bool>('openLiveWallpaperPreview');
  }
}

