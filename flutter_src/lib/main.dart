import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/collections.dart';
import 'src/grid_columns.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppCollections.init();
  await GridColumns.init();
  runApp(const PhotoAlbumApp());
}
