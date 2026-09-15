import 'dart:convert';
import 'dart:io';

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

class WallpaperItem {
  WallpaperItem({
    required this.id,
    required this.mime,
    required this.animated,
    this.filePath = '',
    this.cropZoom = 0.0,
    this.cropFocusX = 0.5,
    this.cropFocusY = 0.5,
  });

  final String id;
  String filePath;
  final String mime;
  bool animated;
  double cropZoom;
  double cropFocusX;
  double cropFocusY;

  bool get cropped => filePath.isNotEmpty;
  bool get isVideo => mime.toLowerCase().startsWith('video/');

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'mime': mime,
        'animated': animated,
        'cropZoom': cropZoom,
        'cropFocusX': cropFocusX,
        'cropFocusY': cropFocusY,
      };

  static WallpaperItem fromJson(Map<String, dynamic> j) => WallpaperItem(
        id: j['id'] as String,
        filePath: (j['filePath'] as String?) ?? '',
        mime: (j['mime'] as String?) ?? '',
        animated: (j['animated'] as bool?) ?? false,
        cropZoom: (j['cropZoom'] as num?)?.toDouble() ?? 0.0,
        cropFocusX: (j['cropFocusX'] as num?)?.toDouble() ?? 0.5,
        cropFocusY: (j['cropFocusY'] as num?)?.toDouble() ?? 0.5,
      );
}

class WallpaperSettings {
  WallpaperSettings({
    this.live = false,
    this.intervalMinutes = 60,
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
        intervalMinutes: (j['intervalMinutes'] as int?) ?? 60,
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
      final old = parse(p.getString(_oldItemsKey));
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
    if (asset.type != AssetType.image && asset.type != AssetType.video) {
      return false;
    }
    final mime = _mimeOf(asset);
    return kWallpaperMimes.contains(mime) ||
        (asset.type == AssetType.video && mime.startsWith('video/'));
  }

  static bool contains(WallpaperTarget t, String id) =>
      listFor(t).value.any((e) => e.id == id);

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
      next.add(WallpaperItem(id: a.id, mime: mime, animated: _looksAnimated(mime)));
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

  static Future<void> _deleteCrop(String path) async {
    if (path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static Future<void> setCropped(
    WallpaperTarget t,
    String id,
    String path, {
    double? zoom,
    double? focusX,
    double? focusY,
  }) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
    final i = next.indexWhere((e) => e.id == id);
    if (i < 0) return;
    next[i].filePath = path;
    if (zoom != null) next[i].cropZoom = zoom;
    if (focusX != null) next[i].cropFocusX = focusX;
    if (focusY != null) next[i].cropFocusY = focusY;
    list.value = next;
    await _persist();
  }

  static Future<void> setTransform(
    WallpaperTarget t,
    String id, {
    required double zoom,
    required double focusX,
    required double focusY,
  }) async {
    final list = listFor(t);
    final next = List<WallpaperItem>.from(list.value);
    final i = next.indexWhere((e) => e.id == id);
    if (i < 0) return;
    next[i].cropZoom = zoom;
    next[i].cropFocusX = focusX;
    next[i].cropFocusY = focusY;
    list.value = next;
    await _persist();
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
