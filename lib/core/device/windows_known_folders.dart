/// 文件输入：Windows Known Folder（图片 / 下载）、环境变量
/// 文件职责：解析 Windows 用户“图片\铥棒文件”“下载\铥棒文件”目录，并提供
///   文件名清洗、同名去重、在资源管理器中打开目录等桌面端工具方法
/// 文件对外接口：WindowsKnownFolders
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_windows/path_provider_windows.dart';

class WindowsKnownFolders {
  WindowsKnownFolders._();

  /// 应用在用户目录下使用的子目录名。
  static const String appFolderName = '铥棒文件';

  static final RegExp _illegalFileNameChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

  /// 用户“图片”目录（FOLDERID_Pictures），失败时回退到 %USERPROFILE%\Pictures。
  static Future<String> picturesPath() async {
    String? resolved;
    try {
      resolved = await PathProviderWindows().getPath(
        WindowsKnownFolder.Pictures,
      );
    } catch (_) {
      resolved = null;
    }
    if (resolved == null || resolved.trim().isEmpty) {
      resolved = p.join(_userProfile(), 'Pictures');
    }
    return resolved;
  }

  /// 用户“下载”目录（FOLDERID_Downloads），失败时回退到 %USERPROFILE%\Downloads。
  static Future<String> downloadsPath() async {
    String? resolved;
    try {
      resolved = (await getDownloadsDirectory())?.path;
    } catch (_) {
      resolved = null;
    }
    if (resolved == null || resolved.trim().isEmpty) {
      resolved = p.join(_userProfile(), 'Downloads');
    }
    return resolved;
  }

  /// 图片\铥棒文件（自动创建）。
  static Future<Directory> appPicturesDirectory() async {
    final dir = Directory(p.join(await picturesPath(), appFolderName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 下载\铥棒文件（自动创建）。
  static Future<Directory> appDownloadsDirectory() async {
    final dir = Directory(p.join(await downloadsPath(), appFolderName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _userProfile() {
    final env = Platform.environment;
    final profile = env['USERPROFILE'] ?? env['HOME'];
    if (profile != null && profile.trim().isNotEmpty) {
      return profile;
    }
    return Directory.systemTemp.path;
  }

  /// 去掉 Windows 文件名非法字符与末尾的点/空格。
  static String sanitizeFileName(String name) {
    var sanitized = name.replaceAll(_illegalFileNameChars, '_').trim();
    while (sanitized.endsWith('.') || sanitized.endsWith(' ')) {
      sanitized = sanitized.substring(0, sanitized.length - 1);
    }
    if (sanitized.isEmpty) {
      sanitized = 'file';
    }
    return sanitized;
  }

  /// 若 [directory]\[fileName] 已存在，则返回追加 “ (n)” 的可用路径。
  static Future<String> uniquePath(String directory, String fileName) async {
    var candidate = p.join(directory, fileName);
    if (!await File(candidate).exists() &&
        !await Directory(candidate).exists()) {
      return candidate;
    }
    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    for (var i = 1; i < 10000; i++) {
      candidate = p.join(directory, '$base ($i)$ext');
      if (!await File(candidate).exists() &&
          !await Directory(candidate).exists()) {
        return candidate;
      }
    }
    return p.join(
      directory,
      '$base (${DateTime.now().millisecondsSinceEpoch})$ext',
    );
  }

  /// 在资源管理器中打开目录；若传入文件路径则打开并选中该文件。
  static Future<bool> revealInExplorer(String path) async {
    if (!Platform.isWindows) {
      return false;
    }
    try {
      final normalized = p.normalize(path);
      if (await File(normalized).exists()) {
        await Process.start('explorer.exe', ['/select,', normalized]);
        return true;
      }
      if (!await Directory(normalized).exists()) {
        await Directory(normalized).create(recursive: true);
      }
      await Process.start('explorer.exe', [normalized]);
      return true;
    } catch (_) {
      return false;
    }
  }
}
