import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/collections.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppCollections.init();
  runApp(const PhotoAlbumApp());
}
