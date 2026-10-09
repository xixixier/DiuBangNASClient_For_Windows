/// 文件输入：dart:io Platform
/// 文件职责：集中判断当前运行平台，供 Android / Windows 双端分支使用
/// 文件对外接口：AppPlatform
import 'dart:io';

import 'package:flutter/foundation.dart';

class AppPlatform {
  AppPlatform._();

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isWindows => !kIsWeb && Platform.isWindows;
  static bool get isMobile => isAndroid || isIOS;
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// 平台标识（与服务端 / 设备展示逻辑使用的小写字符串一致）。
  static String get identifier {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem.toLowerCase();
  }

  /// 是否支持系统相册（photo_manager / wechat_assets_picker）。
  static bool get supportsPhotoLibrary => isAndroid || isIOS;

  /// 是否支持摄像头扫码（mobile_scanner）。
  static bool get supportsCameraQrScan => isAndroid || isIOS;

  /// 是否支持系统托盘与开机自启。
  static bool get supportsDesktopTray => isWindows;
}
