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
        return (a.title ?? '')
            .toLowerCase()
            .compareTo((b.title ?? '').toLowerCase());
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
