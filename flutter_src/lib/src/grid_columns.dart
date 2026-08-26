import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shared, persisted number of columns for the photo grids. Pinch-to-zoom on
/// any grid changes it, and every grid follows the same value.
class GridColumns {
  GridColumns._();

  static const _key = 'grid.columns';
  static const int min = 2;
  static const int max = 6;
  static const int initial = 3;

  static final ValueNotifier<int> count = ValueNotifier<int>(initial);

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    count.value = (p.getInt(_key) ?? initial).clamp(min, max);
  }

  /// Update the column count (clamped) and persist it. No-op if unchanged.
  static void set(int value) {
    final c = value.clamp(min, max);
    if (c == count.value) return;
    count.value = c;
    SharedPreferences.getInstance().then((p) => p.setInt(_key, c));
  }
}

/// Wraps a scrollable photo grid and turns a two-finger pinch into a change of
/// [GridColumns.count]: spread apart → fewer, bigger thumbnails; pinch together
/// → more, smaller ones.
///
/// Uses a passive [Listener] (not a gesture recognizer), so it never competes
/// with the grid's own vertical scrolling — single-finger drags scroll as usual.
class PinchColumns extends StatefulWidget {
  const PinchColumns({super.key, required this.child});

  final Widget child;

  @override
  State<PinchColumns> createState() => _PinchColumnsState();
}

class _PinchColumnsState extends State<PinchColumns> {
  final Map<int, Offset> _points = {};
  double? _baseDistance;
  int? _baseCount;

  void _resetGesture() {
    if (_points.length < 2) {
      _baseDistance = null;
      _baseCount = null;
    }
  }

  void _onMove() {
    if (_points.length != 2) return;
    final pts = _points.values.toList();
    final distance = (pts[0] - pts[1]).distance;
    if (distance <= 0) return;
    _baseDistance ??= distance;
    _baseCount ??= GridColumns.count.value;
    // Bigger finger spread → fewer columns.
    final target = (_baseCount! * _baseDistance! / distance).round();
    if (target != GridColumns.count.value) {
      GridColumns.set(target);
      // Re-anchor so each further step needs a fresh amount of movement.
      _baseDistance = distance;
      _baseCount = GridColumns.count.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        _points[e.pointer] = e.position;
        _resetGesture();
      },
      onPointerMove: (e) {
        if (_points.containsKey(e.pointer)) {
          _points[e.pointer] = e.position;
          _onMove();
        }
      },
      onPointerUp: (e) {
        _points.remove(e.pointer);
        _resetGesture();
      },
      onPointerCancel: (e) {
        _points.remove(e.pointer);
        _resetGesture();
      },
      child: widget.child,
    );
  }
}
