import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int kFlagSystem = 1;
const int kFlagLock = 2;

enum WallpaperTarget { home, lock }

extension WallpaperTargetX on WallpaperTarget {
  String get key => this == WallpaperTarget.home ? 'home' : 'lock';
  int get flag => this == WallpaperTarget.home ? kFlagSystem : kFlagLock;
  String get label => this == WallpaperTarget.home ? '主畫面' : '鎖定';
}

const Set<String> kWallpaperMimes = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
  'video/mp4',
  'video/quicktime',
  'video/x-m4v',
  'video/webm',
};

/// A single framing ("window") of an original image: how much to zoom and where
/// to focus. [zoom] <= 0 means "fit the whole image, centered" (the default);
/// a positive value is a cover-scale multiplier. [focusX]/[focusY] are the
/// normalized point of the original (0..1) that maps to the screen center.
///
/// A wallpaper item owns an ordered list of these windows. The original image
/// is never duplicated; each window is just a different view of it. On the
/// home screen the live wallpaper walks through the windows in order (swipe or
/// timed), so one wide photo can be shown left-part then right-part, etc.
class CropWindow {
  CropWindow({
    this.zoom = 0.0,
    this.focusX = 0.5,
    this.focusY = 0.5,
  });

  double zoom;
  double focusX;
  double focusY;

  /// Whether this window differs from the plain "fit whole image, centered".
  bool get isDefault => zoom <= 0.0 && focusX == 0.5 && focusY == 0.5;

  CropWindow copy() =>
      CropWindow(zoom: zoom, focusX: focusX, focusY: focusY);

  Map<String, dynamic> toJson() => {
        'zoom': zoom,
        'focusX': focusX,
        'focusY': focusY,
      };

  static CropWindow fromJson(Map<String, dynamic> j) => CropWindow(
        zoom: (j['zoom'] as num?)?.toDouble() ?? 0.0,
        focusX: (j['focusX'] as num?)?.toDouble() ?? 0.5,
        focusY: (j['focusY'] as num?)?.toDouble() ?? 0.5,
      );
}

class WallpaperItem {
  WallpaperItem({
    required this.id,
    required this.mime,
    required this.animated,
    List<CropWindow>? windows,
  }) : windows = (windows == null || windows.isEmpty)
            ? <CropWindow>[CropWindow()]
            : windows;

  /// Id of the original photo/video (unique within a list).
  final String id;
  final String mime;
  bool animated;

  /// Ordered framings of the original. Always at least one.
  List<CropWindow> windows;

  bool get isVideo => mime.toLowerCase().startsWith('video/');

  int get windowCount => windows.length;

  /// True once the user has customised any framing (more than one window, or a
  /// single non-default window).
  bool get customized =>
      windows.length > 1 || (windows.isNotEmpty && !windows.first.isDefault);

  Map<String, dynamic> toJson() => {
        'id': id,
        'mime': mime,
        'animated': animated,
        'windows': windows.map((w) => w.toJson()).toList(),
      };

  static WallpaperItem fromJson(Map<String, dynamic> j) {
    final raw = j['windows'];
    List<CropWindow> windows;
    if (raw is List && raw.isNotEmpty) {
      windows = raw
          .map((e) => CropWindow.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      // Migrate a legacy single-crop item (cropZoom/cropFocusX/cropFocusY).
      windows = <CropWindow>[
        CropWindow(
          zoom: (j['cropZoom'] as num?)?.toDouble() ?? 0.0,
          focusX: (j['cropFocusX'] as num?)?.toDouble() ?? 0.5,
          focusY: (j['cropFocusY'] as num?)?.toDouble() ?? 0.5,
        ),
      ];
    }
    return WallpaperItem(
      id: j['id'] as String,
      mime: (j['mime'] as String?) ?? '',
      animated: (j['animated'] as bool?) ?? false,
      windows: windows,
    );
  }
}

class WallpaperSettings {
  WallpaperSettings({
    this.live = false,
    this.intervalMinutes = 5,
    this.shuffle = false,
    this.liveSeconds = 30,
    this.loopsBeforeNext = 1,
  });

  bool live;
  int intervalMinutes;
  bool shuffle;
  int liveSeconds;
  int loopsBeforeNext;

  WallpaperSettings copyWith({
    bool? live,
    int? intervalMinutes,
    bool? shuffle,
    int? liveSeconds,
    int? loopsBeforeNext,
  }) =>
      WallpaperSettings(
        live: live ?? this.live,
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
        shuffle: shuffle ?? this.shuffle,
        liveSeconds: liveSeconds ?? this.liveSeconds,
        loopsBeforeNext: loopsBeforeNext ?? this.loopsBeforeNext,
      );

  Map<String, dynamic> toJson() => {
        'live': live,
        'intervalMinutes': intervalMinutes,
        'shuffle': shuffle,
        'liveSeconds': liveSeconds,
        'loopsBeforeNext': loopsBeforeNext,
      };

  static WallpaperSettings fromJson(Map<String, dynamic> j) => WallpaperSettings(
        live: (j['live'] as bool?) ?? false,
        intervalMinutes: (j['intervalMinutes'] as int?) ?? 5,
        shuffle: (j['shuffle'] as bool?) ?? false,
        liveSeconds: (j['liveSeconds'] as int?) ?? 30,
        loopsBeforeNext: (j['loopsBeforeNext'] as int?) ?? 1,
      );
}

class WallpaperPlaylist {
  WallpaperPlaylist._();

  static const _homeKey = 'wallpaper_home_items';
  static const _lockKey = 'wallpaper_lock_items';
  static const _settingsKey = 'wallpaper_playlist_settings';
  static const _oldItemsKey = 'wallpaper_playlist_items';

  static final ValueNotifier<List<WallpaperItem>> homeItems =
      ValueNotifier<List<WallpaperItem>>([]);
  static final ValueNotifier<List<WallpaperItem>> lockItems =
      ValueNotifier<List<WallpaperItem>>([]);
  static final ValueNotifier<WallpaperSettings> settings =
      ValueNotifier<WallpaperSettings>(WallpaperSettings());

  static ValueNotifier<List<WallpaperItem>> listFor(WallpaperTarget t) =>
      t == WallpaperTarget.home ? homeItems : lockItems;

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();

    List<WallpaperItem> parse(String? raw) {
      if (raw == null || raw.isEmpty) return [];
      try {
        return (jsonDecode(raw) as List)
            .map((e) => WallpaperItem.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        return [];
      }
    }

    final rawHome = p.getString(_homeKey);
    final rawLock = p.getString(_lockKey);

    if (rawHome == null && rawLock == null) {
      // Very old single-list layout: everything lived under one key.
      homeItems.value = parse(p.getString(_oldItemsKey));
      lockItems.value = [];
    } else {
      homeItems.value = parse(rawHome);
      lockItems.value = parse(rawLock);
    }

    final rawSettings = p.getString(_settingsKey);
    if (rawSettings != null && rawSettings.isNotEmpty) {
      try {
        settings.value = WallpaperSettings.fromJson(
            jsonDecode(rawSettings) as Map<String, dynamic>);
      } catch (_) {
        settings.value = WallpaperSettings();
      }
    }
  }

  static Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _homeKey, jsonEncode(homeItems.value.map((e) => e.toJson()).toList()));
    await p.setString(
        _lockKey, jsonEncode(lockItems.value.map((e) => e.toJson()).toList()));
    await p.setString(_settingsKey, jsonEncode(settings.value.toJson()));
  }

  static bool accepts(AssetEntity asset) {
    if (asset.type != AssetType.image && asset.type != AssetType.video) {
      return false;
    }
    final mime = _mimeOf(asset);
    return kWallpaperMimes.contains(mime) ||
        (asset.type == AssetType.video && mime.startsWith('video/'));
  }

  static bool contains(WallpaperTarget t, String id) =>
      listFor(t).value.any((e) => e.id == id);

  static WallpaperItem? itemFor(WallpaperTarget t, String id) {
    for (final e in listFor(t).value) {
      if (e.id == id) return e;
    }
    return null;
  }

  static Future<bool> add(AssetEntity asset, WallpaperTarget t) async {
    if (!accepts(asset) || contains(t, asset.id)) return false;
    final mime = _mimeOf(asset);
    final list = listFor(t);
    list.value = [
      ...list.value,
      WallpaperItem(id: asset.id, mime: mime, animated: _looksAnimated(mime)),
    ];
    await _persist();
    return true;
  }

  static Future<int> addAll(
      Iterable<AssetEntity> assets, WallpaperTarget t) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
    final have = next.map((e) => e.id).toSet();
    var added = 0;
    for (final a in assets) {
      if (!accepts(a) || have.contains(a.id)) continue;
      final mime = _mimeOf(a);
      next.add(
          WallpaperItem(id: a.id, mime: mime, animated: _looksAnimated(mime)));
      have.add(a.id);
      added++;
    }
    if (added > 0) {
      list.value = next;
      await _persist();
    }
    return added;
  }

  static Future<void> removeAt(WallpaperTarget t, int index) async {
    final list = listFor(t);
    if (index < 0 || index >= list.value.length) return;
    final next = List<WallpaperItem>.from(list.value)..removeAt(index);
    list.value = next;
    await _persist();
  }

  static Future<void> reorder(
      WallpaperTarget t, int oldIndex, int newIndex) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
    if (oldIndex < 0 || oldIndex >= next.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), moved);
    list.value = next;
    await _persist();
  }

  static Future<void> clear(WallpaperTarget t) async {
    final list = listFor(t);
    if (list.value.isEmpty) return;
    list.value = [];
    await _persist();
  }

  // --- Window (crop) operations -------------------------------------------

  /// Replaces the whole window list of [id] with a copy of [windows]
  /// (at least one window is always kept).
  static Future<void> setWindows(
      WallpaperTarget t, String id, List<CropWindow> windows) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
    final i = next.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final copied = windows.map((w) => w.copy()).toList();
    next[i].windows = copied.isEmpty ? <CropWindow>[CropWindow()] : copied;
    list.value = next;
    await _persist();
  }

  /// Appends a new framing to [id] and returns its index.
  static Future<int> addWindow(
      WallpaperTarget t, String id, CropWindow window) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
    final i = next.indexWhere((e) => e.id == id);
    if (i < 0) return -1;
    next[i].windows = [...next[i].windows, window.copy()];
    list.value = next;
    await _persist();
    return next[i].windows.length - 1;
  }

  static Future<void> updateWindow(
      WallpaperTarget t, String id, int index, CropWindow window) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
    final i = next.indexWhere((e) => e.id == id);
    if (i < 0 || index < 0 || index >= next[i].windows.length) return;
    final ws = List<CropWindow>.from(next[i].windows);
    ws[index] = window.copy();
    next[i].windows = ws;
    list.value = next;
    await _persist();
  }

  /// Removes a framing. Keeps at least one window (a no-op on the last one).
  static Future<void> removeWindow(
      WallpaperTarget t, String id, int index) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
    final i = next.indexWhere((e) => e.id == id);
    if (i < 0 || next[i].windows.length <= 1) return;
    if (index < 0 || index >= next[i].windows.length) return;
    final ws = List<CropWindow>.from(next[i].windows)..removeAt(index);
    next[i].windows = ws;
    list.value = next;
    await _persist();
  }

  static Future<void> reorderWindows(
      WallpaperTarget t, String id, int oldIndex, int newIndex) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
    final i = next.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final ws = List<CropWindow>.from(next[i].windows);
    if (oldIndex < 0 || oldIndex >= ws.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = ws.removeAt(oldIndex);
    ws.insert(newIndex.clamp(0, ws.length), moved);
    next[i].windows = ws;
    list.value = next;
    await _persist();
  }

  /// Sets a single framing for [id] (used by the video framing page, which has
  /// exactly one window). Replaces any existing windows.
  static Future<void> setTransform(
    WallpaperTarget t,
    String id, {
    required double zoom,
    required double focusX,
    required double focusY,
  }) async {
    await setWindows(t, id, [
      CropWindow(zoom: zoom, focusX: focusX, focusY: focusY),
    ]);
  }

  static Future<void> updateSettings(WallpaperSettings s) async {
    settings.value = s;
    await _persist();
  }

  static String _mimeOf(AssetEntity asset) {
    final m = asset.mimeType?.toLowerCase();
    if (m != null && m.isNotEmpty) return m;
    final name = (asset.title ?? '').toLowerCase();
    if (asset.type == AssetType.video) {
      if (name.endsWith('.mov')) return 'video/quicktime';
      if (name.endsWith('.m4v')) return 'video/x-m4v';
      if (name.endsWith('.webm')) return 'video/webm';
      return 'video/mp4';
    }
    if (name.endsWith('.gif')) return 'image/gif';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    return '';
  }

  static bool _looksAnimated(String mime) {
    final m = mime.toLowerCase();
    return m.contains('gif') || m.contains('webp') || m.startsWith('video/');
  }
}
