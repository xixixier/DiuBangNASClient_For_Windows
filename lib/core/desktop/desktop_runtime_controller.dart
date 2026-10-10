/// 文件输入：window_manager、system_tray、launch_at_startup、桌面偏好设置
/// 文件职责：Windows 桌面端运行时：窗口尺寸/标题、关闭到托盘、托盘菜单、开机自启。
///   托盘驻留时进程不退出，进程内定时备份（WindowsBackupSchedulerBridge）得以继续执行。
///   实现参考 DiuBangNASServer_Windows 的 DesktopRuntimeController。
/// 文件对外接口：DesktopRuntimeController
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path/path.dart' as path;
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import '../device/windows_known_folders.dart';
import 'desktop_settings_store.dart';

class DesktopRuntimeController with WindowListener {
  DesktopRuntimeController._();

  static final DesktopRuntimeController instance = DesktopRuntimeController._();

  static const String appTitle = '铥棒文件';

  /// 开机自启时附带的参数：启动后直接隐藏到托盘。
  static const String launchMinimizedArgument = '--launch-minimized-to-tray';

  static const Size minimumWindowSize = Size(1000, 680);
  static const Size initialWindowSize = Size(1280, 800);

  final WindowManager _windowManager = WindowManager.instance;
  final SystemTray _systemTray = SystemTray();

  DesktopSettingsStore? _settingsStore;
  ValueListenable<String?>? _backgroundStatus;
  bool _initialized = false;
  bool _trayReady = false;
  bool _trayInitAttempted = false;
  bool _launchHidden = false;
  bool _windowPresented = false;
  bool _isExiting = false;
  bool _isHidingWindow = false;
  bool _isConfirmingExit = false;

  /// 根 Navigator，用于在退出前弹确认框（由 GoRouter 使用）。
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// 返回尚未完成的传输数量（进行中 / 排队 / 等待处理冲突）。
  int Function()? activeTransferCount;

  static bool get isSupported => Platform.isWindows;

  static bool shouldLaunchHidden(List<String> startupArgs) {
    return isSupported && startupArgs.contains(launchMinimizedArgument);
  }

  DesktopSettingsStore? get settingsStore => _settingsStore;

  /// 托盘图标随 Flutter 资源打包：data/flutter_assets/windows/runner/resources/app_icon.ico
  static String? resolveTrayIconPath() {
    if (!Platform.isWindows) {
      return null;
    }
    final executableDir = path.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      path.join(
        executableDir,
        'data',
        'flutter_assets',
        'windows',
        'runner',
        'resources',
        'app_icon.ico',
      ),
      path.join(executableDir, 'resources', 'app_icon.ico'),
      path.join(
        Directory.current.path,
        'windows',
        'runner',
        'resources',
        'app_icon.ico',
      ),
    ];
    for (final candidate in candidates) {
      final normalized = path.normalize(candidate);
      if (File(normalized).existsSync()) {
        return normalized;
      }
    }
    return null;
  }

  /// runApp 之前调用：初始化 window_manager、开机自启配置。
  Future<void> prepareLaunch({
    required DesktopSettingsStore settingsStore,
    required bool launchHidden,
  }) async {
    if (!isSupported) {
      return;
    }
    _settingsStore = settingsStore;
    _launchHidden = launchHidden;

    _configureLaunchAtStartup(settingsStore.value);
    unawaited(_syncLaunchAtStartup(settingsStore.value, failSilently: true));

    if (_initialized) {
      return;
    }
    await _windowManager.ensureInitialized();
    _windowManager.addListener(this);
    await _windowManager.setPreventClose(true);
    await _windowManager.setResizable(true);
    await _windowManager.setMinimumSize(minimumWindowSize);
    _initialized = true;
  }

  /// 订阅后台任务状态（例如定时备份进度），显示在托盘提示中。
  void attachBackgroundStatus(ValueListenable<String?> status) {
    _backgroundStatus?.removeListener(_onBackgroundStatusChanged);
    _backgroundStatus = status;
    status.addListener(_onBackgroundStatusChanged);
  }

  void _onBackgroundStatusChanged() {
    if (!_trayReady) return;
    final status = _backgroundStatus?.value;
    unawaited(
      _systemTray
          .setToolTip(status == null ? appTitle : '$appTitle - $status')
          .catchError((Object _) {}),
    );
  }

  /// runApp 之后（首帧后）调用：显示窗口或直接驻留托盘。
  Future<void> presentWindowAfterFirstFrame() async {
    if (!isSupported || !_initialized || _windowPresented) {
      return;
    }
    _windowPresented = true;

    final savedBounds = _usableSavedBounds();
    await _windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: savedBounds?.size ?? initialWindowSize,
        minimumSize: minimumWindowSize,
        center: savedBounds == null,
        skipTaskbar: false,
        title: appTitle,
      ),
      () async {
        if (savedBounds != null) {
          await _windowManager.setPosition(savedBounds.topLeft);
        }
        if (_settingsStore?.windowMaximized ?? false) {
          await _windowManager.maximize();
        }
        await _ensureTrayInitialized();
        if (_launchHidden && _trayReady) {
          await _hideWindowToTray();
          return;
        }
        await showWindow();
      },
    );
  }

  Future<void> applySettings(DesktopSettings settings) async {
    if (!isSupported) {
      return;
    }
    final store = _settingsStore;
    if (store == null) {
      return;
    }
    final previous = store.value;
    _configureLaunchAtStartup(settings);
    try {
      await _syncLaunchAtStartup(settings, failSilently: false);
    } catch (_) {
      _configureLaunchAtStartup(previous);
      rethrow;
    }
    await store.save(settings);
    await _safeRefreshTray();
  }

  Future<void> showWindow() async {
    if (!isSupported) {
      return;
    }
    await _windowManager.setSkipTaskbar(false);
    await _windowManager.show();
    await _windowManager.focus();
    await _safeRefreshTray();
  }

  /// 退出应用。
  ///
  /// 以前是 `windowManager.destroy()` 后让 Flutter 引擎自己收尾：引擎要等 Dart
  /// 虚拟机里的 WebSocket、HTTP 长连接、后台 isolate、播放器线程等全部结束，
  /// 点了 × 之后窗口会卡住好几秒才消失。现在先立刻隐藏窗口，做几件必要的
  /// 收尾（保存窗口位置、移除托盘图标，均带超时），然后直接结束进程，
  /// 剩下的资源交给操作系统回收。
  Future<void> exitApplication() async {
    if (!isSupported || _isExiting) {
      return;
    }
    if (!await _confirmExitIfBusy()) {
      return;
    }
    _isExiting = true;
    _windowManager.removeListener(this);
    try {
      await _flushWindowBounds().timeout(
        const Duration(milliseconds: 400),
        onTimeout: () {},
      );
      await _windowManager.hide().timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
      if (_trayReady) {
        await _systemTray.destroy().timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => false,
        );
      }
    } catch (error) {
      debugPrint('[Desktop] exit cleanup failed: $error');
    } finally {
      exit(0);
    }
  }

  /// 有未完成的传输时先确认；返回 true 表示继续退出。
  Future<bool> _confirmExitIfBusy() async {
    if (_isConfirmingExit) return false;
    int count = 0;
    try {
      count = activeTransferCount?.call() ?? 0;
    } catch (_) {}
    if (count <= 0) return true;
    final context = navigatorKey.currentContext;
    if (context == null) return true;

    _isConfirmingExit = true;
    try {
      // 从托盘菜单退出时窗口可能是隐藏的，先显示出来再弹框
      if (!await _windowManager.isVisible()) {
        await showWindow();
      }
      if (!context.mounted) return true;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('还有传输未完成'),
          content: Text('当前有 $count 个上传或下载任务还没完成，退出后会被中断。确定要退出吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB64848),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('仍然退出'),
            ),
          ],
        ),
      );
      return confirmed == true;
    } finally {
      _isConfirmingExit = false;
    }
  }

  Future<void> _flushWindowBounds() async {
    _boundsSaveTimer?.cancel();
    try {
      if (await _windowManager.isMaximized() ||
          await _windowManager.isMinimized() ||
          !await _windowManager.isVisible()) {
        return;
      }
      final bounds = await _windowManager.getBounds();
      await _settingsStore?.saveWindowBounds(bounds);
    } catch (_) {}
  }

  Timer? _boundsSaveTimer;

  /// 只在记录看起来仍位于屏幕上时恢复，避免外接显示器拔掉后窗口跑到屏幕外。
  Rect? _usableSavedBounds() {
    final bounds = _settingsStore?.windowBounds;
    if (bounds == null) return null;
    if (bounds.left < -200 || bounds.top < -50) return null;
    if (bounds.left > 6000 || bounds.top > 4000) return null;
    final width = bounds.width < minimumWindowSize.width
        ? minimumWindowSize.width
        : bounds.width;
    final height = bounds.height < minimumWindowSize.height
        ? minimumWindowSize.height
        : bounds.height;
    return Rect.fromLTWH(bounds.left, bounds.top, width, height);
  }

  void _scheduleBoundsSave() {
    _boundsSaveTimer?.cancel();
    _boundsSaveTimer = Timer(const Duration(milliseconds: 600), () async {
      try {
        if (await _windowManager.isMaximized() ||
            await _windowManager.isMinimized() ||
            !await _windowManager.isVisible()) {
          return;
        }
        final bounds = await _windowManager.getBounds();
        await _settingsStore?.saveWindowBounds(bounds);
      } catch (_) {}
    });
  }

  @override
  void onWindowResized() => _scheduleBoundsSave();

  @override
  void onWindowMoved() => _scheduleBoundsSave();

  @override
  void onWindowMaximize() {
    unawaited(_settingsStore?.saveWindowMaximized(true));
  }

  @override
  void onWindowUnmaximize() {
    unawaited(_settingsStore?.saveWindowMaximized(false));
    _scheduleBoundsSave();
  }

  @override
  void onWindowClose() {
    if (_isExiting) {
      return;
    }
    final settings = _settingsStore?.value;
    if (settings != null && settings.closeToTray && _trayReady) {
      unawaited(_hideWindowToTray());
      return;
    }
    unawaited(exitApplication());
  }

  Future<void> _ensureTrayInitialized() async {
    if (_trayReady || _trayInitAttempted) {
      return;
    }
    _trayInitAttempted = true;
    final iconPath = resolveTrayIconPath();
    if (iconPath == null) {
      debugPrint('[Desktop] tray icon not found, tray disabled');
      return;
    }
    try {
      await _systemTray.initSystemTray(iconPath: iconPath, toolTip: appTitle);
      _trayReady = true;
      _systemTray.registerSystemTrayEventHandler((eventName) {
        switch (eventName) {
          case kSystemTrayEventClick:
          case kSystemTrayEventDoubleClick:
            unawaited(showWindow());
            return;
          case kSystemTrayEventRightClick:
            unawaited(
              _safeRefreshTray().then((_) => _systemTray.popUpContextMenu()),
            );
            return;
        }
      });
      await _safeRefreshTray();
    } catch (error) {
      _trayReady = false;
      debugPrint('[Desktop] tray init failed: $error');
    }
  }

  Future<void> _safeRefreshTray() async {
    try {
      await _refreshTray();
    } catch (error) {
      debugPrint('[Desktop] tray refresh failed: $error');
    }
  }

  Future<void> _refreshTray() async {
    if (!isSupported || !_trayReady) {
      return;
    }
    final settings = _settingsStore?.value;
    final isVisible = await _windowManager.isVisible();
    final menu = Menu();
    await menu.buildFrom(<MenuItemBase>[
      MenuItemLabel(
        label: isVisible ? '隐藏到托盘' : '显示主窗口',
        onClicked: (_) {
          unawaited(isVisible ? _hideWindowToTray() : showWindow());
        },
      ),
      MenuItemLabel(
        label: '打开下载文件夹',
        onClicked: (_) {
          unawaited(_openDownloadsFolder());
        },
      ),
      MenuSeparator(),
      MenuItemCheckbox(
        label: '开机自启',
        checked: settings?.launchAtStartup ?? false,
        onClicked: (_) {
          final current = _settingsStore?.value;
          if (current == null) return;
          unawaited(
            applySettings(
              current.copyWith(launchAtStartup: !current.launchAtStartup),
            ).catchError((Object error) {
              debugPrint('[Desktop] toggle launch at startup failed: $error');
            }),
          );
        },
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: '退出$appTitle',
        onClicked: (_) {
          unawaited(exitApplication());
        },
      ),
    ]);
    await _systemTray.setContextMenu(menu);
  }

  Future<void> _openDownloadsFolder() async {
    final dir = await WindowsKnownFolders.appDownloadsDirectory();
    await WindowsKnownFolders.revealInExplorer(dir.path);
  }

  Future<void> _hideWindowToTray() async {
    if (_isHidingWindow) {
      return;
    }
    if (!_trayReady) {
      await showWindow();
      return;
    }
    _isHidingWindow = true;
    try {
      await _windowManager.setSkipTaskbar(true);
      await _windowManager.hide();
      await _safeRefreshTray();
    } finally {
      _isHidingWindow = false;
    }
  }

  void _configureLaunchAtStartup(DesktopSettings settings) {
    launchAtStartup.setup(
      appName: appTitle,
      appPath: Platform.resolvedExecutable,
      args: settings.launchMinimized
          ? const <String>[launchMinimizedArgument]
          : const <String>[],
    );
  }

  Future<void> _syncLaunchAtStartup(
    DesktopSettings settings, {
    required bool failSilently,
  }) async {
    try {
      final isEnabled = await launchAtStartup.isEnabled();
      if (isEnabled == settings.launchAtStartup) {
        if (isEnabled) {
          // 参数（是否隐藏启动）可能变化，重新写入注册表
          await launchAtStartup.enable();
        }
        return;
      }
      final succeeded = settings.launchAtStartup
          ? await launchAtStartup.enable()
          : await launchAtStartup.disable();
      if (!succeeded) {
        throw StateError(settings.launchAtStartup ? '启用开机自启失败' : '关闭开机自启失败');
      }
    } catch (error) {
      if (!failSilently) {
        rethrow;
      }
      debugPrint('[Desktop] launch at startup sync failed: $error');
    }
  }
}
