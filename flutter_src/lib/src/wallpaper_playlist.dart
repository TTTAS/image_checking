import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WallpaperManager screen flags (match Android's values so native can pass them
/// straight through).
const int kFlagSystem = 1; // home screen
const int kFlagLock = 2; // lock screen

/// Which screen a playlist / crop belongs to. Home and lock are independent
/// lists, each cropped and rotated separately.
enum WallpaperTarget { home, lock }

extension WallpaperTargetX on WallpaperTarget {
  String get key => this == WallpaperTarget.home ? 'home' : 'lock';
  int get flag => this == WallpaperTarget.home ? kFlagSystem : kFlagLock;
  String get label => this == WallpaperTarget.home ? '主畫面' : '鎖定';
}

/// Image types accepted into the playlist. Videos are excluded.
const Set<String> kWallpaperMimes = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
};

/// One entry in a wallpaper playlist.
class WallpaperItem {
  WallpaperItem({
    required this.id,
    required this.mime,
    required this.animated,
    this.filePath = '',
  });

  /// Source photo's asset id.
  final String id;

  /// Path of the user-cropped image saved in the app's private dir
  /// (filesDir/wallpaper_playlist/<home|lock>/<id>.jpg). Empty until the user
  /// crops it (or the first apply center-crops and stores one).
  String filePath;

  final String mime;
  bool animated;

  bool get cropped => filePath.isNotEmpty;

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

/// Rotation settings shared by both lists.
class WallpaperSettings {
  WallpaperSettings({this.intervalMinutes = 60, this.shuffle = false});

  /// Minutes between swaps. WorkManager's real floor is ~15 min.
  int intervalMinutes;
  bool shuffle;

  WallpaperSettings copyWith({int? intervalMinutes, bool? shuffle}) =>
      WallpaperSettings(
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
        shuffle: shuffle ?? this.shuffle,
      );

  Map<String, dynamic> toJson() =>
      {'intervalMinutes': intervalMinutes, 'shuffle': shuffle};

  static WallpaperSettings fromJson(Map<String, dynamic> j) => WallpaperSettings(
        intervalMinutes: (j['intervalMinutes'] as int?) ?? 60,
        shuffle: (j['shuffle'] as bool?) ?? false,
      );
}

/// Two independent playlists (home / lock) plus shared settings, persisted via
/// SharedPreferences. Cropped image files live in the app's private dir and are
/// written by the native side; here we only track their paths.
class WallpaperPlaylist {
  WallpaperPlaylist._();

  static const _homeKey = 'wallpaper_home_items';
  static const _lockKey = 'wallpaper_lock_items';
  static const _settingsKey = 'wallpaper_playlist_settings';
  static const _oldItemsKey = 'wallpaper_playlist_items'; // pre-split single list

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
      // Migrate the old single list (if any) into the home list.
      final old = parse(p.getString(_oldItemsKey));
      // Old entries were never really cropped; start fresh on filePath.
      for (final it in old) {
        it.filePath = '';
      }
      homeItems.value = old;
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
    if (asset.type != AssetType.image) return false;
    return kWallpaperMimes.contains(_mimeOf(asset));
  }

  static bool contains(WallpaperTarget t, String id) =>
      listFor(t).value.any((e) => e.id == id);

  /// Adds one asset to [t]. Returns true if added (false if unsupported or
  /// already present).
  static Future<bool> add(AssetEntity asset, WallpaperTarget t) async {
    if (!accepts(asset) || contains(t, asset.id)) return false;
    final mime = _mimeOf(asset);
    final list = listFor(t);
    list.value = [
      ...list.value,
      WallpaperItem(id: asset.id, mime: mime, animated: _isGif(mime)),
    ];
    await _persist();
    return true;
  }

  /// Adds several assets to [t], skipping unsupported / duplicates. Returns how
  /// many were added.
  static Future<int> addAll(
      Iterable<AssetEntity> assets, WallpaperTarget t) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
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
      list.value = next;
      await _persist();
    }
    return added;
  }

  static Future<void> removeAt(WallpaperTarget t, int index) async {
    final list = listFor(t);
    if (index < 0 || index >= list.value.length) return;
    final removed = list.value[index];
    final next = List<WallpaperItem>.from(list.value)..removeAt(index);
    list.value = next;
    await _persist();
    // Delete this entry's cropped cache file (app-private jpg, NOT the gallery
    // original). Ignore failures.
    await _deleteCrop(removed.filePath);
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
    final gone = List<WallpaperItem>.from(list.value);
    list.value = [];
    await _persist();
    for (final it in gone) {
      await _deleteCrop(it.filePath);
    }
  }

  /// Deletes a cropped cache file (app-private). Never touches gallery originals.
  static Future<void> _deleteCrop(String path) async {
    if (path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // best-effort
    }
  }

  /// Records the cropped file path for an entry in [t].
  static Future<void> setCropped(
      WallpaperTarget t, String id, String path) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
    final i = next.indexWhere((e) => e.id == id);
    if (i < 0) return;
    next[i].filePath = path;
    list.value = next;
    await _persist();
  }

  static Future<void> updateSettings(WallpaperSettings s) async {
    settings.value = s;
    await _persist();
  }

  // ---- helpers ----------------------------------------------------------

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
