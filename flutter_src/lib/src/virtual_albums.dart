import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A private sentinel so [VirtualAlbum.copyWith] can tell "leave coverId
/// unchanged" apart from "set coverId to null".
const Object _unset = Object();

/// One app-local virtual album ("我的相簿"): a named group of photo asset ids.
///
/// Purely virtual — this NEVER moves, copies, renames or deletes files on disk
/// and needs no storage permission (`MANAGE_EXTERNAL_STORAGE` is never
/// touched). A photo may belong to any number of albums at once (tag-like
/// membership). Persisted as JSON in SharedPreferences, exactly like
/// [AppCollections] / [FolderNames].
class VirtualAlbum {
  const VirtualAlbum({
    required this.id,
    required this.name,
    required this.assetIds,
    this.coverId,
  });

  final String id;
  final String name;

  /// Asset ids in insertion order (newest additions appended).
  final List<String> assetIds;

  /// Chosen cover asset id, or null to fall back to the first asset.
  final String? coverId;

  int get count => assetIds.length;

  VirtualAlbum copyWith({
    String? name,
    List<String>? assetIds,
    Object? coverId = _unset,
  }) {
    return VirtualAlbum(
      id: id,
      name: name ?? this.name,
      assetIds: assetIds ?? this.assetIds,
      coverId:
          identical(coverId, _unset) ? this.coverId : coverId as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'cover': coverId,
        'assets': assetIds,
      };

  static VirtualAlbum? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final name = j['name'];
    if (id is! String || name is! String) return null;
    final assets =
        (j['assets'] as List?)?.whereType<String>().toList() ?? <String>[];
    final cover = j['cover'];
    return VirtualAlbum(
      id: id,
      name: name,
      assetIds: assets,
      coverId: cover is String ? cover : null,
    );
  }
}

/// Store of the user's virtual albums, kept in SharedPreferences.
///
/// The whole list lives in one JSON string under [_key]. The [albums] notifier
/// lets every screen rebuild when an album is created, renamed, deleted or has
/// photos added/removed.
class VirtualAlbums {
  VirtualAlbums._();

  static const _key = 'virtual_albums';

  static final ValueNotifier<List<VirtualAlbum>> albums =
      ValueNotifier<List<VirtualAlbum>>([]);

  static final Random _rng = Random();

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      albums.value = decoded
          .whereType<Map<String, dynamic>>()
          .map(VirtualAlbum.fromJson)
          .whereType<VirtualAlbum>()
          .toList();
    } catch (_) {
      // Corrupt value: start clean rather than crashing on launch.
    }
  }

  static Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode(albums.value.map((a) => a.toJson()).toList()),
    );
  }

  static VirtualAlbum? byId(String id) {
    for (final a in albums.value) {
      if (a.id == id) return a;
    }
    return null;
  }

  static String _newId() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '${_rng.nextInt(1 << 32).toRadixString(36)}';

  /// Creates an empty album and returns its generated id. Duplicate names are
  /// allowed (albums are keyed by id, not name).
  static Future<String> create(String name) async {
    final id = _newId();
    albums.value = [
      ...albums.value,
      VirtualAlbum(id: id, name: name, assetIds: const []),
    ];
    await _persist();
    return id;
  }

  static Future<void> rename(String id, String name) async {
    albums.value = [
      for (final a in albums.value)
        if (a.id == id) a.copyWith(name: name) else a,
    ];
    await _persist();
  }

  static Future<void> remove(String id) async {
    albums.value = albums.value.where((a) => a.id != id).toList();
    await _persist();
  }

  /// Adds [ids] to the album, skipping ones already in it. Returns how many
  /// were newly added.
  static Future<int> addAssets(String id, Iterable<String> ids) async {
    var added = 0;
    albums.value = [
      for (final a in albums.value)
        if (a.id == id)
          () {
            final list = List<String>.from(a.assetIds);
            final existing = list.toSet();
            for (final newId in ids) {
              if (existing.add(newId)) {
                list.add(newId);
                added++;
              }
            }
            return a.copyWith(assetIds: list);
          }()
        else
          a,
    ];
    await _persist();
    return added;
  }

  static Future<void> removeAssets(String id, Iterable<String> ids) async {
    final drop = ids.toSet();
    albums.value = [
      for (final a in albums.value)
        if (a.id == id)
          a.copyWith(
            assetIds: a.assetIds.where((x) => !drop.contains(x)).toList(),
            coverId: (a.coverId != null && drop.contains(a.coverId))
                ? null
                : a.coverId,
          )
        else
          a,
    ];
    await _persist();
  }

  static Future<void> setCover(String id, String? assetId) async {
    albums.value = [
      for (final a in albums.value)
        if (a.id == id) a.copyWith(coverId: assetId) else a,
    ];
    await _persist();
  }

  /// Drops [ids] from every album (e.g. after the photos are deleted from the
  /// device). Mirrors [AppCollections.forget].
  static Future<void> forget(Iterable<String> ids) async {
    final drop = ids.toSet();
    if (drop.isEmpty) return;
    albums.value = [
      for (final a in albums.value)
        a.copyWith(
          assetIds: a.assetIds.where((x) => !drop.contains(x)).toList(),
          coverId: (a.coverId != null && drop.contains(a.coverId))
              ? null
              : a.coverId,
        ),
    ];
    await _persist();
  }
}
