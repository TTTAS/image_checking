import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/collections.dart';
import 'src/folder_covers.dart';
import 'src/folder_names.dart';
import 'src/grid_columns.dart';
import 'src/wallpaper_playlist.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppCollections.init();
  await GridColumns.init();
  await FolderCovers.init();
  await FolderNames.init();
  await WallpaperPlaylist.init();
  runApp(const PhotoAlbumApp());
}
