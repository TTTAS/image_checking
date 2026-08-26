import 'package:flutter/foundation.dart';

/// Tracks multi-select state for a photo grid.
class SelectionController extends ChangeNotifier {
  bool _active = false;
  final Set<String> _ids = {};

  bool get active => _active;
  Set<String> get ids => _ids;
  int get count => _ids.length;
  bool isSelected(String id) => _ids.contains(id);

  /// Enter selection mode with one photo already selected (long-press).
  void enter(String id) {
    _active = true;
    _ids
      ..clear()
      ..add(id);
    notifyListeners();
  }

  void toggle(String id) {
    if (!_ids.add(id)) _ids.remove(id);
    if (_ids.isEmpty) _active = false;
    notifyListeners();
  }

  void clear() {
    _active = false;
    _ids.clear();
    notifyListeners();
  }
}
