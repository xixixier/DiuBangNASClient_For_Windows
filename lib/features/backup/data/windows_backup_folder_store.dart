/// 文件输入：SharedPreferences
/// 文件职责：Windows 端“备份文件夹”列表持久化（替代 Android 的整机图库），
///   手动“备份文件夹”与定时备份计划共用同一份文件夹列表
/// 文件对外接口：WindowsBackupFolderStore
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class WindowsBackupFolderStore {
  WindowsBackupFolderStore({required SharedPreferences prefs}) : _prefs = prefs;

  static const String _keyFolders = 'windows_backup_source_folders';

  /// Windows 定时备份计划在 backup_plans.source_path 中使用的标记值。
  static const String planSourcePath = 'windows-folders://selected';

  final SharedPreferences _prefs;

  List<String> loadFolders() {
    final raw = _prefs.getString(_keyFolders);
    if (raw == null || raw.trim().isEmpty) {
      return const <String>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <String>[];
      }
      return decoded
          .map((value) => value?.toString() ?? '')
          .where((value) => value.trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<void> saveFolders(List<String> folders) async {
    final normalized = <String>[];
    final seen = <String>{};
    for (final folder in folders) {
      final value = p.normalize(folder.trim());
      if (value.isEmpty) continue;
      if (seen.add(value.toLowerCase())) {
        normalized.add(value);
      }
    }
    await _prefs.setString(_keyFolders, jsonEncode(normalized));
  }

  /// 添加文件夹；若已存在（大小写不敏感）返回 false。
  Future<bool> addFolder(String folder) async {
    final current = loadFolders();
    final normalized = p.normalize(folder.trim());
    if (normalized.isEmpty) return false;
    if (current.any((f) => f.toLowerCase() == normalized.toLowerCase())) {
      return false;
    }
    await saveFolders(<String>[...current, normalized]);
    return true;
  }

  Future<void> removeFolder(String folder) async {
    final target = p.normalize(folder.trim()).toLowerCase();
    await saveFolders(
      loadFolders()
          .where((f) => p.normalize(f).toLowerCase() != target)
          .toList(growable: false),
    );
  }
}
