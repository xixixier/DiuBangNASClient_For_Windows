/// 文件输入：Flutter 运行时入口、bootstrap
/// 文件职责：提供应用唯一入口，完成平台初始化（Windows：sqflite FFI、窗口、托盘）后启动应用引导
/// 文件对外接口：main
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app/bootstrap.dart';
import 'core/platform/app_platform.dart';
import 'core/storage/platform_sqlite.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android 使用 media_kit_libs_android_video，Windows 使用 media_kit_libs_windows_video
  MediaKit.ensureInitialized();

  if (AppPlatform.isWindows) {
    // sqfliteFfiInit() + databaseFactory = databaseFactoryFfi
    PlatformSqlite.ensureInitialized();
  }

  PaintingBinding.instance.imageCache.maximumSize = 2000;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 200 << 20;

  await bootstrap(startupArgs: args);
}
