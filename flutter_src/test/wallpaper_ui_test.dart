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
      find.ancestor(of: find.text('加入鎖定輪播'),
          matching: find.byType(PopupMenuItem<String>)),
    );
    expect(lock.enabled, isTrue);
    await tester.tap(find.text('設為桌布'));
    await tester.pumpAndSettle();
    expect(find.byType(WallpaperCropPage), findsOneWidget);
    expect(find.byTooltip('輪播清單'), findsOneWidget);
    expect(find.byTooltip('輪播設定'), findsOneWidget);
    // A missing/unreadable file must show an error and disable Apply.
    expect(find.textContaining('無法播放影片'), findsOneWidget);
    final apply = tester.widget<FilledButton>(find.ancestor(
      of: find.text('設為桌布'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    ));
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
    await tester.tap(find.byKey(const ValueKey('home_10')));
    await tester.tap(find.byKey(const ValueKey('lock_60')));
    await tester.tap(find.byType(SwitchListTile));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(WallpaperPlaylist.settings.value.liveSeconds, 10);
    expect(WallpaperPlaylist.settings.value.lockLiveSeconds, 60);
    expect(WallpaperPlaylist.settings.value.shuffle, isTrue);
  });

  test('Lock video crop persists without changing the home copy', () async {
    final asset = AssetEntity(id: 'shared-video', typeInt: 2,
        width: 320, height: 240, title: 'sample.mp4');
    expect(await WallpaperPlaylist.add(asset, WallpaperTarget.home), isTrue);
    expect(await WallpaperPlaylist.add(asset, WallpaperTarget.lock), isTrue);
    await WallpaperPlaylist.setCropped(WallpaperTarget.lock, asset.id, '',
        zoom: 2, focusX: .25, focusY: .75, sourceWidth: 320, sourceHeight: 240);
    await WallpaperPlaylist.init();
    final home = WallpaperPlaylist.homeItems.value.single;
    final lock = WallpaperPlaylist.lockItems.value.single;
    expect(lock.video, isTrue);
    expect(lock.cropped, isTrue);
    expect(lock.cropZoom, 2);
    expect(lock.cropFocusY, .75);
    expect(lock.sourceWidth, 320);
    expect(home.cropZoom, 0);
    expect(home.cropped, isFalse);
  });

  testWidgets('Lock tab edits its own interval and applies its own list', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: WallpaperPage(initialTarget: WallpaperTarget.lock),
    ));
    await tester.pumpAndSettle();
    expect(find.text('套用鎖定輪播'), findsOneWidget);
    await tester.tap(find.text('10 秒'));
    await tester.pumpAndSettle();
    expect(WallpaperPlaylist.settings.value.lockLiveSeconds, 10);
    expect(WallpaperPlaylist.settings.value.liveSeconds, 30);
    await tester.tap(find.text('主畫面'));
    await tester.pumpAndSettle();
    expect(find.text('套用主畫面輪播'), findsOneWidget);
    expect(WallpaperPlaylist.settings.value.liveSeconds, 30);
  });
}
