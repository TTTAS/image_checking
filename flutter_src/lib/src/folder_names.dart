import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-chosen display names for folders: bucket id -> custom name.
///
/// App-local only — this never renames the real folder on disk; it just
/// changes how the folder is labelled inside this app. Stored as a JSON map.
class FolderNames {
  FolderNames._();

  static const _key = 'folder_names';

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

  /// The custom name for a folder, or null if none is set.
  static String? nameOf(String bucketId) => map.value[bucketId];

  static Future<void> set(String bucketId, String name) async {
    final m = Map<String, String>.from(map.value);
    m[bucketId] = name;
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
