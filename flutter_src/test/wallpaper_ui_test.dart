import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/src/viewer.dart';
import '../lib/src/wallpaper_crop_page.dart';
import '../lib/src/wallpaper_page.dart';
import '../lib/src/wallpaper_playlist.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WallpaperPlaylist.settings.value = WallpaperSettings();
    WallpaperPlaylist.homeItems.value = [];
    WallpaperPlaylist.lockItems.value = [];
  });

  testWidgets('Video has single wallpaper, playlist and shared settings entries',
      (tester) async {
    final asset = AssetEntity(id: 'video-test', typeInt: 2,
        width: 320, height: 240, title: 'sample.mp4');
    await tester.pumpWidget(MaterialApp(
      home: ViewerPage(assets: [asset], initialIndex: 0),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('桌布'));
    await tester.pumpAndSettle();
    for (final text in ['設為桌布', '加入主畫面輪播', '輪播清單', '輪播設定']) {
      expect(find.text(text), findsOneWidget);
    }
    final lock = tester.widget<PopupMenuItem<String>>(
      find.ancestor(of: find.text('加入鎖定輪播（僅支援圖片）'),
          matching: find.byType(PopupMenuItem<String>)),
    );
    expect(lock.enabled, isFalse);
    await tester.tap(find.text('設為桌布'));
    await tester.pumpAndSettle();
    expect(find.byType(WallpaperCropPage), findsOneWidget);
    expect(find.byTooltip('輪播清單'), findsOneWidget);
    expect(find.byTooltip('輪播設定'), findsOneWidget);
    // A missing/unreadable file must show an error and disable Apply.
    expect(find.textContaining('無法播放影片'), findsOneWidget);
    final apply = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '設為桌布'));
    expect(apply.onPressed, isNull);
  });

  testWidgets('Shared settings persist video interval and shuffle', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(
        onPressed: () => showWallpaperSettings(context),
        child: const Text('設定'),
      )),
    )));
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    expect(find.text('主畫面每項播放時間（圖片、GIF、影片皆適用）'), findsOneWidget);
    await tester.tap(find.text('10 秒'));
    await tester.tap(find.byType(SwitchListTile));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(WallpaperPlaylist.settings.value.liveSeconds, 10);
    expect(WallpaperPlaylist.settings.value.shuffle, isTrue);
  });
}
