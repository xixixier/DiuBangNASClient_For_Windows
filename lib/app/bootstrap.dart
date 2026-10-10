/// 文件输入：Flutter 绑定初始化、依赖注册器、本地存储初始化
/// 文件职责：完成应用启动前初始化，并调用 runApp；Windows 额外初始化窗口/托盘/开机自启
///   与进程内定时备份调度器
/// 文件对外接口：bootstrap
import 'dart:async';

import '../features/transfer/presentation/cubit/transfer_state.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'di/service_locator.dart';
import '../core/desktop/desktop_runtime_controller.dart';
import '../core/desktop/desktop_settings_store.dart';
import '../core/platform/app_platform.dart';
import '../core/storage/key_value_store.dart';

Future<void> bootstrap({List<String> startupArgs = const <String>[]}) async {
  final prefs = await SharedPreferences.getInstance();
  final keyValueStore = KeyValueStore(prefs: prefs);

  await configureDependencies(
    keyValueStore: keyValueStore,
    sharedPreferences: prefs,
  );

  if (AppPlatform.isWindows) {
    try {
      await DesktopRuntimeController.instance.prepareLaunch(
        settingsStore: DesktopSettingsStore(prefs: prefs),
        launchHidden: DesktopRuntimeController.shouldLaunchHidden(startupArgs),
      );
    } catch (error) {
      debugPrint('[Desktop] prepareLaunch failed: $error');
    }
  }

  runApp(const App());

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (AppPlatform.isWindows) {
      unawaited(
        DesktopRuntimeController.instance
            .presentWindowAfterFirstFrame()
            .catchError((Object error) {
              debugPrint('[Desktop] present window failed: $error');
            }),
      );
    }
    unawaited(_initializeDeferredStartupTasks());
  });
}

Future<void> _initializeDeferredStartupTasks() async {
  if (AppPlatform.isWindows) {
    DesktopRuntimeController.instance.activeTransferCount = () {
      final state = serviceLocator.transferCubit.state;
      return state is TransferLoaded ? state.activeCount : 0;
    };
    final bridge = serviceLocator.windowsBackupBridge;
    await bridge.start();
    DesktopRuntimeController.instance.attachBackgroundStatus(
      bridge.statusMessage,
    );
  }
  await serviceLocator.backupPlanScheduler.syncPlans();
}
