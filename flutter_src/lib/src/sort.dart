import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What we sort photos by.
enum SortField { date, name, size }

/// Direction of the sort.
enum SortDir { asc, desc }

class SortOption {
  const SortOption(this.field, this.dir);
  final SortField field;
  final SortDir dir;

  /// The date view groups photos by day *only* when sorting by date.
  bool get groupsByDay => field == SortField.date;

  SortOption copyWith({SortField? field, SortDir? dir}) =>
      SortOption(field ?? this.field, dir ?? this.dir);

  String encode() => '${field.name}:${dir.name}';

  static SortOption decode(String? raw, SortOption fallback) {
    if (raw == null || !raw.contains(':')) return fallback;
    final parts = raw.split(':');
    final field = SortField.values
        .where((f) => f.name == parts[0])
        .cast<SortField?>()
        .firstWhere((f) => f != null, orElse: () => null);
    final dir = SortDir.values
        .where((d) => d.name == parts[1])
        .cast<SortDir?>()
        .firstWhere((d) => d != null, orElse: () => null);
    if (field == null || dir == null) return fallback;
    return SortOption(field, dir);
  }

  /// Human label for the current selection, used as a tooltip / heading.
  String get label {
    final f = switch (field) {
      SortField.date => '日期',
      SortField.name => '檔名',
      SortField.size => '大小',
    };
    final d = switch ((field, dir)) {
      (SortField.date, SortDir.desc) => '新→舊',
      (SortField.date, SortDir.asc) => '舊→新',
      (SortField.name, SortDir.asc) => 'A→Z',
      (SortField.name, SortDir.desc) => 'Z→A',
      (SortField.size, SortDir.desc) => '大→小',
      (SortField.size, SortDir.asc) => '小→大',
    };
    return '$f（$d）';
  }
}

/// Persist / restore the user's last chosen sort per "scope"
/// (e.g. the date tab, the folder list, a specific folder view).
class SortStore {
  static Future<SortOption> load(String key, SortOption fallback) async {
    final prefs = await SharedPreferences.getInstance();
    return SortOption.decode(prefs.getString('sort.$key'), fallback);
  }

  static Future<void> save(String key, SortOption option) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sort.$key', option.encode());
  }
}

/// Compares two names the way people read them: runs of digits are compared
/// by numeric value, so "2" comes before "10" (plain string order would give
/// 1, 10, 19, 2, 20, ...). Letters compare case-insensitively.
int naturalCompare(String a, String b) {
  final x = a.toLowerCase();
  final y = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i);
    final cy = y.codeUnitAt(j);
    if (_isDigit(cx) && _isDigit(cy)) {
      final si = i;
      final sj = j;
      while (i < x.length && _isDigit(x.codeUnitAt(i))) {
        i++;
      }
      while (j < y.length && _isDigit(y.codeUnitAt(j))) {
        j++;
      }
      // Skip leading zeros, then the longer number is the bigger one.
      var zi = si;
      while (zi < i - 1 && x.codeUnitAt(zi) == 0x30) {
        zi++;
      }
      var zj = sj;
      while (zj < j - 1 && y.codeUnitAt(zj) == 0x30) {
        zj++;
      }
      final nx = x.substring(zi, i);
      final ny = y.substring(zj, j);
      if (nx.length != ny.length) return nx.length - ny.length;
      final c = nx.compareTo(ny);
      if (c != 0) return c;
      // Same value: "01" vs "1" — fewer leading zeros first.
      if (i - si != j - sj) return (i - si) - (j - sj);
    } else {
      if (cx != cy) return cx - cy;
      i++;
      j++;
    }
  }
  final rest = (x.length - i) - (y.length - j);
  if (rest != 0) return rest;
  return a.compareTo(b);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Sorts a list of assets in place-ish (returns a new list).
///
/// [sizeOf] supplies file byte sizes for size sorting (loaded lazily by the
/// caller, since [AssetEntity] does not expose byte length directly).
List<AssetEntity> sortAssets(
  List<AssetEntity> assets,
  SortOption option, {
  Map<String, int>? sizeOf,
}) {
  final list = List<AssetEntity>.from(assets);
  int cmp(AssetEntity a, AssetEntity b) {
    switch (option.field) {
      case SortField.date:
        return a.createDateTime.compareTo(b.createDateTime);
      case SortField.name:
        return naturalCompare(a.title ?? '', b.title ?? '');
      case SortField.size:
        final sa = sizeOf?[a.id] ?? 0;
        final sb = sizeOf?[b.id] ?? 0;
        return sa.compareTo(sb);
    }
  }

  list.sort(cmp);
  if (option.dir == SortDir.desc) {
    return list.reversed.toList();
  }
  return list;
}

/// The set of choices shown in the top-right sort menu.
const List<SortOption> kSortChoices = [
  SortOption(SortField.date, SortDir.desc),
  SortOption(SortField.date, SortDir.asc),
  SortOption(SortField.name, SortDir.asc),
  SortOption(SortField.name, SortDir.desc),
  SortOption(SortField.size, SortDir.desc),
  SortOption(SortField.size, SortDir.asc),
];
