/// 文件输入：path_provider
/// 文件职责：统一应用私有数据目录。Android 沿用 ApplicationDocuments；
///   Windows 的 ApplicationDocuments 是用户“文档”文件夹，不适合放内部缓存，
///   因此改用 %APPDATA% 下的 ApplicationSupport 目录。
/// 文件对外接口：AppDirectories
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppDirectories {
  AppDirectories._();

  static Future<Directory> appData() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return getApplicationSupportDirectory();
    }
    return getApplicationDocumentsDirectory();
  }
}
