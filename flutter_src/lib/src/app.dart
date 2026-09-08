import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'date_tab.dart';
import 'favorites_tab.dart';
import 'folders_tab.dart';

/// Fired when a bottom-nav button is tapped while its tab is already showing.
/// The tab listens and scrolls its grid back to the top.
class ScrollToTopSignal extends ChangeNotifier {
  void fire() => notifyListeners();
}

class PhotoAlbumApp extends StatelessWidget {
  const PhotoAlbumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '相簿',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const _PermissionGate(),
    );
  }
}

/// Requests photo-library permission, then shows the two-tab home.
class _PermissionGate extends StatefulWidget {
  const _PermissionGate();

  @override
  State<_PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<_PermissionGate> {
  PermissionState? _state;
  bool _requesting = true;

  @override
  void initState() {
    super.initState();
    _request();
  }

  Future<void> _request() async {
    setState(() => _requesting = true);
    final ps = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    setState(() {
      _state = ps;
      _requesting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_requesting) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final granted =
        _state == PermissionState.authorized || _state == PermissionState.limited;
    if (!granted) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.photo_library_outlined, size: 48),
                const SizedBox(height: 16),
                const Text(
                  '需要相片存取權限才能顯示你的照片',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _request,
                  child: const Text('重新授權'),
                ),
                TextButton(
                  onPressed: () => PhotoManager.openSetting(),
                  child: const Text('前往系統設定'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return const _Home();
  }
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  int _index = 0;

  // One signal per tab; firing it tells that tab to scroll to the top.
  final _signals = List.generate(3, (_) => ScrollToTopSignal());

  // Kept alive so switching tabs does not reload the whole library each time.
  late final _pages = [
    DateTab(scrollToTop: _signals[0]),
    FoldersTab(scrollToTop: _signals[1]),
    FavoritesTab(scrollToTop: _signals[2]),
  ];

  @override
  void dispose() {
    for (final s in _signals) {
      s.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          // Re-tapping the active tab scrolls it to the top; otherwise switch.
          if (i == _index) {
            _signals[i].fire();
          } else {
            setState(() => _index = i);
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '日期',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '資料夾',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            selectedIcon: Icon(Icons.favorite),
            label: '我的最愛',
          ),
        ],
      ),
    );
  }
}
