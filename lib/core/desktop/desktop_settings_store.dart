/// 文件输入：SharedPreferences
/// 文件职责：Windows 桌面端偏好设置（关闭窗口最小化到托盘、开机自启、自启时隐藏窗口）
/// 文件对外接口：DesktopSettingsStore、DesktopSettings
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class DesktopSettings {
  const DesktopSettings({
    required this.closeToTray,
    required this.launchAtStartup,
    required this.launchMinimized,
  });

  /// 点击窗口关闭按钮时隐藏到系统托盘（而不是退出），以便定时备份继续执行。
  final bool closeToTray;

  /// 登录 Windows 后自动启动。
  final bool launchAtStartup;

  /// 开机自启时不显示主窗口，直接驻留托盘。
  final bool launchMinimized;

  DesktopSettings copyWith({
    bool? closeToTray,
    bool? launchAtStartup,
    bool? launchMinimized,
  }) {
    return DesktopSettings(
      closeToTray: closeToTray ?? this.closeToTray,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      launchMinimized: launchMinimized ?? this.launchMinimized,
    );
  }
}

class DesktopSettingsStore {
  DesktopSettingsStore({required SharedPreferences prefs}) : _prefs = prefs {
    settings = ValueNotifier<DesktopSettings>(_load());
  }

  static const String _keyCloseToTray = 'desktop_close_to_tray';
  static const String _keyLaunchAtStartup = 'desktop_launch_at_startup';
  static const String _keyLaunchMinimized = 'desktop_launch_minimized';

  final SharedPreferences _prefs;
  late final ValueNotifier<DesktopSettings> settings;

  DesktopSettings get value => settings.value;

  DesktopSettings _load() {
    return DesktopSettings(
      closeToTray: _prefs.getBool(_keyCloseToTray) ?? true,
      launchAtStartup: _prefs.getBool(_keyLaunchAtStartup) ?? false,
      launchMinimized: _prefs.getBool(_keyLaunchMinimized) ?? true,
    );
  }

  Future<void> save(DesktopSettings next) async {
    await _prefs.setBool(_keyCloseToTray, next.closeToTray);
    await _prefs.setBool(_keyLaunchAtStartup, next.launchAtStartup);
    await _prefs.setBool(_keyLaunchMinimized, next.launchMinimized);
    settings.value = next;
  }

  static const String _keyWindowBounds = 'desktop_window_bounds';
  static const String _keyWindowMaximized = 'desktop_window_maximized';

  /// 上次关闭时的窗口位置与大小（逻辑像素），没有记录时返回 null。
  Rect? get windowBounds {
    final raw = _prefs.getStringList(_keyWindowBounds);
    if (raw == null || raw.length != 4) return null;
    final values = raw.map(double.tryParse).toList();
    if (values.any((v) => v == null)) return null;
    final rect = Rect.fromLTWH(values[0]!, values[1]!, values[2]!, values[3]!);
    if (rect.width < 200 || rect.height < 200) return null;
    return rect;
  }

  bool get windowMaximized => _prefs.getBool(_keyWindowMaximized) ?? false;

  Future<void> saveWindowBounds(Rect bounds) async {
    await _prefs.setStringList(_keyWindowBounds, [
      bounds.left.toStringAsFixed(0),
      bounds.top.toStringAsFixed(0),
      bounds.width.toStringAsFixed(0),
      bounds.height.toStringAsFixed(0),
    ]);
  }

  Future<void> saveWindowMaximized(bool maximized) async {
    await _prefs.setBool(_keyWindowMaximized, maximized);
  }
}
