import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-local "wallpaper playlist": the ordered set of photos / GIFs / WebPs the
/// user wants to rotate as their wallpaper, plus the rotation settings.
///
/// This is milestone M1 (skeleton only): it stores and manages the list and the
/// settings so the UI works end to end. It does NOT yet copy files or actually
/// change the wallpaper — that arrives in M2 (static rotation) and M3 (live
/// wallpaper). See the implementation brief for the full plan.
///
/// Follows the same shape as [AppCollections]: a tiny static holder backed by
/// [SharedPreferences], exposing [ValueNotifier]s the UI listens to.

/// The kinds of images we accept into the playlist. Videos are deliberately
/// excluded in this version.
const Set<String> kWallpaperMimes = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
};

/// One entry in the wallpaper playlist.
class WallpaperItem {
  WallpaperItem({
    required this.id,
    required this.mime,
    required this.animated,
    this.filePath = '',
  });

  /// The source photo's asset id (from photo_manager / MediaStore).
  final String id;

  /// Path of the copy inside the app's private files dir. Empty until M2 fills
  /// it in when the user taps "apply" (the background service/worker only ever
  /// reads this copy, never the gallery).
  String filePath;

  /// e.g. image/gif, image/webp, image/jpeg.
  final String mime;

  /// Whether this is (or may be) an animated image.
  ///
  /// NOTE: mime alone is not enough — plenty of WebP files are static. So here
  /// GIF counts as animated and everything else (WebP included) starts as
  /// false; mode B's decoder is the real authority and overrides this later.
  bool animated;

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'mime': mime,
        'animated': animated,
      };

  static WallpaperItem fromJson(Map<String, dynamic> j) => WallpaperItem(
        id: j['id'] as String,
        filePath: (j['filePath'] as String?) ?? '',
        mime: (j['mime'] as String?) ?? '',
        animated: (j['animated'] as bool?) ?? false,
      );
}

/// How the wallpaper rotation behaves. Persisted alongside the item list.
class WallpaperSettings {
  WallpaperSettings({
    this.live = false,
    this.intervalMinutes = 60,
    this.loopsBeforeNext = 1,
    this.liveSeconds = 0,
    this.flags = flagSystem,
    this.fit = 'crop',
    this.shuffle = false,
  });

  /// Matches Android's WallpaperManager flags so the native side can pass them
  /// straight through.
  static const int flagSystem = 1; // FLAG_SYSTEM (home screen)
  static const int flagLock = 2; // FLAG_LOCK (lock screen)

  /// false = static rotation (mode A); true = live wallpaper (mode B).
  bool live;

  /// Mode A: minutes between swaps. WorkManager's real floor is ~15 min, so the
  /// UI must not offer anything shorter (and must say "about", not "exactly").
  int intervalMinutes;

  /// Mode B: advance to the next image after this many playback loops.
  int loopsBeforeNext;

  /// Mode B: alternatively, advance after this many seconds. Precedence is
  /// fixed: if [liveSeconds] > 0 it wins; otherwise [loopsBeforeNext] is used.
  int liveSeconds;

  /// Mode A apply target: FLAG_SYSTEM / FLAG_LOCK (bitwise OR for both).
  int flags;

  /// 'crop' = center-crop to fill (default); 'contain' = fit whole image with a
  /// backing color. 'contain' is only implemented in M4, so the UI disables it
  /// until then.
  String fit;

  /// Play the list in a random order instead of list order.
  bool shuffle;

  WallpaperSettings copyWith({
    bool? live,
    int? intervalMinutes,
    int? loopsBeforeNext,
    int? liveSeconds,
    int? flags,
    String? fit,
    bool? shuffle,
  }) =>
      WallpaperSettings(
        live: live ?? this.live,
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
        loopsBeforeNext: loopsBeforeNext ?? this.loopsBeforeNext,
        liveSeconds: liveSeconds ?? this.liveSeconds,
        flags: flags ?? this.flags,
        fit: fit ?? this.fit,
        shuffle: shuffle ?? this.shuffle,
      );

  Map<String, dynamic> toJson() => {
        'live': live,
        'intervalMinutes': intervalMinutes,
        'loopsBeforeNext': loopsBeforeNext,
        'liveSeconds': liveSeconds,
        'flags': flags,
        'fit': fit,
        'shuffle': shuffle,
      };

  static WallpaperSettings fromJson(Map<String, dynamic> j) => WallpaperSettings(
        live: (j['live'] as bool?) ?? false,
        intervalMinutes: (j['intervalMinutes'] as int?) ?? 60,
        loopsBeforeNext: (j['loopsBeforeNext'] as int?) ?? 1,
        liveSeconds: (j['liveSeconds'] as int?) ?? 0,
        flags: (j['flags'] as int?) ?? flagSystem,
        fit: (j['fit'] as String?) ?? 'crop',
        shuffle: (j['shuffle'] as bool?) ?? false,
      );
}

/// The playlist store. Load once in `main()` via [init].
class WallpaperPlaylist {
  WallpaperPlaylist._();

  static const _itemsKey = 'wallpaper_playlist_items';
  static const _settingsKey = 'wallpaper_playlist_settings';

  /// Ordered playlist entries. The UI listens to this.
  static final ValueNotifier<List<WallpaperItem>> items =
      ValueNotifier<List<WallpaperItem>>([]);

  /// Rotation settings. The UI listens to this.
  static final ValueNotifier<WallpaperSettings> settings =
      ValueNotifier<WallpaperSettings>(WallpaperSettings());

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final rawItems = p.getString(_itemsKey);
    if (rawItems != null && rawItems.isNotEmpty) {
      try {
        final list = (jsonDecode(rawItems) as List)
            .map((e) => WallpaperItem.fromJson(e as Map<String, dynamic>))
            .toList();
        items.value = list;
      } catch (_) {
        items.value = [];
      }
    }
    final rawSettings = p.getString(_settingsKey);
    if (rawSettings != null && rawSettings.isNotEmpty) {
      try {
        settings.value =
            WallpaperSettings.fromJson(jsonDecode(rawSettings) as Map<String, dynamic>);
      } catch (_) {
        settings.value = WallpaperSettings();
      }
    }
  }

  static Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _itemsKey, jsonEncode(items.value.map((e) => e.toJson()).toList()));
    await p.setString(_settingsKey, jsonEncode(settings.value.toJson()));
  }

  static bool contains(String id) => items.value.any((e) => e.id == id);

  /// Whether [asset] is an image type we accept into the playlist.
  static bool accepts(AssetEntity asset) {
    if (asset.type != AssetType.image) return false;
    return kWallpaperMimes.contains(_mimeOf(asset));
  }

  /// Adds one asset. Returns true if it was added (false if unsupported or
  /// already present).
  static Future<bool> add(AssetEntity asset) async {
    if (!accepts(asset) || contains(asset.id)) return false;
    final mime = _mimeOf(asset);
    items.value = [
      ...items.value,
      WallpaperItem(id: asset.id, mime: mime, animated: _isGif(mime)),
    ];
    await _persist();
    return true;
  }

  /// Adds several assets, skipping unsupported types and duplicates. Returns how
  /// many were actually added.
  static Future<int> addAll(Iterable<AssetEntity> assets) async {
    final next = List<WallpaperItem>.from(items.value);
    final have = next.map((e) => e.id).toSet();
    var added = 0;
    for (final a in assets) {
      if (!accepts(a) || have.contains(a.id)) continue;
      final mime = _mimeOf(a);
      next.add(WallpaperItem(id: a.id, mime: mime, animated: _isGif(mime)));
      have.add(a.id);
      added++;
    }
    if (added > 0) {
      items.value = next;
      await _persist();
    }
    return added;
  }

  static Future<void> removeAt(int index) async {
    if (index < 0 || index >= items.value.length) return;
    final next = List<WallpaperItem>.from(items.value)..removeAt(index);
    items.value = next;
    await _persist();
  }

  static Future<void> reorder(int oldIndex, int newIndex) async {
    final next = List<WallpaperItem>.from(items.value);
    if (oldIndex < 0 || oldIndex >= next.length) return;
    // ReorderableListView reports newIndex assuming the item is still present.
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), moved);
    items.value = next;
    await _persist();
  }

  static Future<void> clear() async {
    if (items.value.isEmpty) return;
    items.value = [];
    await _persist();
  }

  static Future<void> updateSettings(WallpaperSettings s) async {
    settings.value = s;
    await _persist();
  }

  // ---- helpers ----------------------------------------------------------

  /// Best-effort mime for an asset: prefer the reported mime, fall back to the
  /// file extension in the title.
  static String _mimeOf(AssetEntity asset) {
    final m = asset.mimeType?.toLowerCase();
    if (m != null && m.isNotEmpty) return m;
    final name = (asset.title ?? '').toLowerCase();
    if (name.endsWith('.gif')) return 'image/gif';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    return '';
  }

  static bool _isGif(String mime) => mime == 'image/gif';
}
