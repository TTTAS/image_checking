import 'package:flutter_test/flutter_test.dart';
import 'package:photo_album/src/wallpaper_playlist.dart';

void main() {
  group('CropWindow', () {
    test('round-trips through JSON', () {
      final w = CropWindow(zoom: 1.8, focusX: 0.2, focusY: 0.7);
      final back = CropWindow.fromJson(w.toJson());
      expect(back.zoom, 1.8);
      expect(back.focusX, 0.2);
      expect(back.focusY, 0.7);
    });

    test('default framing is detected', () {
      expect(CropWindow().isDefault, isTrue);
      expect(CropWindow(zoom: 1.2).isDefault, isFalse);
      expect(CropWindow(focusX: 0.1).isDefault, isFalse);
    });
  });

  group('WallpaperItem', () {
    test('always keeps at least one window', () {
      final item = WallpaperItem(id: 'a', mime: 'image/jpeg', animated: false);
      expect(item.windows.length, 1);
      expect(item.windows.first.isDefault, isTrue);
      expect(item.windowCount, 1);
      expect(item.customized, isFalse);
    });

    test('multiple windows round-trip through JSON in order', () {
      final item = WallpaperItem(
        id: 'wide',
        mime: 'image/jpeg',
        animated: false,
        windows: [
          CropWindow(zoom: 2, focusX: 0.15, focusY: 0.5),
          CropWindow(zoom: 2, focusX: 0.85, focusY: 0.5),
        ],
      );
      final back = WallpaperItem.fromJson(item.toJson());
      expect(back.windowCount, 2);
      expect(back.customized, isTrue);
      expect(back.windows[0].focusX, 0.15);
      expect(back.windows[1].focusX, 0.85);
    });

    test('migrates a legacy single-crop item into one window', () {
      final legacy = {
        'id': 'old',
        'mime': 'image/png',
        'animated': false,
        'filePath': '/data/old.jpg',
        'cropZoom': 1.5,
        'cropFocusX': 0.3,
        'cropFocusY': 0.4,
      };
      final item = WallpaperItem.fromJson(legacy);
      expect(item.windowCount, 1);
      expect(item.windows.first.zoom, 1.5);
      expect(item.windows.first.focusX, 0.3);
      expect(item.windows.first.focusY, 0.4);
    });

    test('legacy item with no crop fields becomes one default window', () {
      final item = WallpaperItem.fromJson({
        'id': 'plain',
        'mime': 'image/jpeg',
        'animated': false,
      });
      expect(item.windowCount, 1);
      expect(item.windows.first.isDefault, isTrue);
    });
  });
}
