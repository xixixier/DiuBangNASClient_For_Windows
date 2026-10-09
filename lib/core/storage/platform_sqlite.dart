/// 文件输入：当前平台
/// 文件职责：桌面端（Windows）初始化 sqflite FFI，并提供数据库工厂与数据库目录
/// 文件对外接口：PlatformSqlite
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

class PlatformSqlite {
  PlatformSqlite._();

  static bool _initialized = false;

  static bool get usesFfi =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Windows：调用 sqfliteFfiInit() 并把全局 databaseFactory 指向 FFI 实现。
  /// Release 包中的 sqlite3.dll 由 sqlite3_flutter_libs 编译并放在 exe 同级目录。
  static void ensureInitialized() {
    if (!usesFfi || _initialized) {
      return;
    }
    ffi.sqfliteFfiInit();
    sqflite.databaseFactory = ffi.databaseFactoryFfi;
    _initialized = true;
  }

  static sqflite.DatabaseFactory get databaseFactory {
    if (!usesFfi) {
      return sqflite.databaseFactory;
    }
    ensureInitialized();
    return ffi.databaseFactoryFfi;
  }

  /// 数据库所在目录。桌面端默认的 getDatabasesPath() 指向工作目录下的
  /// .dart_tool，安装到 Program Files 后不可写，因此改用 %APPDATA% 下的应用支持目录。
  static Future<String> databasesPath() async {
    if (!usesFfi) {
      return sqflite.getDatabasesPath();
    }
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory('${supportDir.path}${Platform.pathSeparator}databases');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }
}
