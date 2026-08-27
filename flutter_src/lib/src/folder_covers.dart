import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-chosen cover photo per folder: bucket id -> asset id.
///
/// App-local; when a folder has no entry the folder list falls back to the
/// first photo by filename. Stored as a JSON map in SharedPreferences.
class FolderCovers {
  FolderCovers._();

  static const _key = 'folder_covers';

  static final ValueNotifier<Map<String, String>> map =
      ValueNotifier<Map<String, String>>({});

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      map.value = decoded.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      // Corrupt value: start clean.
    }
  }

  static Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(map.value));
  }

  /// The chosen cover asset id for a folder, or null if none is set.
  static String? coverOf(String bucketId) => map.value[bucketId];

  static Future<void> set(String bucketId, String assetId) async {
    final m = Map<String, String>.from(map.value);
    m[bucketId] = assetId;
    map.value = m;
    await _persist();
  }

  static Future<void> clear(String bucketId) async {
    if (!map.value.containsKey(bucketId)) return;
    final m = Map<String, String>.from(map.value)..remove(bucketId);
    map.value = m;
    await _persist();
  }
}
