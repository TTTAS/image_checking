import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-local sets of "favorite" and "hidden" photos, keyed by asset id.
///
/// These live only inside this app (Android has no reliable way to sync a
/// per-photo favorite/hidden flag back to the system gallery).
class AppCollections {
  AppCollections._();

  static const _favKey = 'favorites';
  static const _hidKey = 'hidden';

  static final ValueNotifier<Set<String>> favorites =
      ValueNotifier<Set<String>>({});
  static final ValueNotifier<Set<String>> hidden =
      ValueNotifier<Set<String>>({});

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    favorites.value = (p.getStringList(_favKey) ?? const []).toSet();
    hidden.value = (p.getStringList(_hidKey) ?? const []).toSet();
  }

  static Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_favKey, favorites.value.toList());
    await p.setStringList(_hidKey, hidden.value.toList());
  }

  static bool isFavorite(String id) => favorites.value.contains(id);
  static bool isHidden(String id) => hidden.value.contains(id);

  static Future<void> toggleFavorite(String id) async {
    final s = Set<String>.from(favorites.value);
    if (!s.add(id)) s.remove(id);
    favorites.value = s;
    await _persist();
  }

  static Future<void> setFavorite(Iterable<String> ids, bool on) async {
    final s = Set<String>.from(favorites.value);
    if (on) {
      s.addAll(ids);
    } else {
      s.removeAll(ids);
    }
    favorites.value = s;
    await _persist();
  }

  static Future<void> toggleHidden(String id) async {
    final s = Set<String>.from(hidden.value);
    if (!s.add(id)) s.remove(id);
    hidden.value = s;
    await _persist();
  }

  static Future<void> setHidden(Iterable<String> ids, bool on) async {
    final s = Set<String>.from(hidden.value);
    if (on) {
      s.addAll(ids);
    } else {
      s.removeAll(ids);
    }
    hidden.value = s;
    await _persist();
  }

  /// Drop ids that no longer exist (e.g. after deletion) from both sets.
  static Future<void> forget(Iterable<String> ids) async {
    final f = Set<String>.from(favorites.value)..removeAll(ids);
    final h = Set<String>.from(hidden.value)..removeAll(ids);
    favorites.value = f;
    hidden.value = h;
    await _persist();
  }
}
