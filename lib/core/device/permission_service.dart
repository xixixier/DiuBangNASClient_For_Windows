/// 文件输入：文件读写、相机、麦克风等系统权限请求
/// 文件职责：统一处理设备权限申请与检查（Windows 桌面端无运行时权限，一律视为已授权）
/// 文件对外接口：PermissionService
/// 文件包含：PermissionService
import 'package:permission_handler/permission_handler.dart'
    as permission_handler;

import '../platform/app_platform.dart';

class PermissionService {
  /// Android / iOS 才需要运行时权限。
  bool get _requiresRuntimePermissions => AppPlatform.isMobile;

  Future<bool> requestStoragePermission() async {
    if (!_requiresRuntimePermissions) return true;
    final status = await permission_handler.Permission.storage.request();
    return status.isGranted;
  }

  Future<bool> requestCameraPermission() async {
    if (!_requiresRuntimePermissions) return true;
    final status = await permission_handler.Permission.camera.request();
    return status.isGranted;
  }

  Future<bool> requestMicrophonePermission() async {
    if (!_requiresRuntimePermissions) return true;
    final status = await permission_handler.Permission.microphone.request();
    return status.isGranted;
  }

  Future<bool> requestNotificationPermission() async {
    if (!_requiresRuntimePermissions) return true;
    final status = await permission_handler.Permission.notification.request();
    return status.isGranted;
  }

  Future<bool> checkStoragePermission() async {
    if (!_requiresRuntimePermissions) return true;
    final status = await permission_handler.Permission.storage.status;
    return status.isGranted;
  }

  Future<bool> checkCameraPermission() async {
    if (!_requiresRuntimePermissions) return true;
    final status = await permission_handler.Permission.camera.status;
    return status.isGranted;
  }

  Future<bool> checkMicrophonePermission() async {
    if (!_requiresRuntimePermissions) return true;
    final status = await permission_handler.Permission.microphone.status;
    return status.isGranted;
  }

  Future<bool> checkNotificationPermission() async {
    if (!_requiresRuntimePermissions) return true;
    final status = await permission_handler.Permission.notification.status;
    return status.isGranted;
  }

  Future<void> openAppSettings() async {
    if (!_requiresRuntimePermissions) return;
    await permission_handler.openAppSettings();
  }

  Future<
    Map<permission_handler.Permission, permission_handler.PermissionStatus>
  >
  requestMultiplePermissions(
    List<permission_handler.Permission> permissions,
  ) async {
    if (!_requiresRuntimePermissions) {
      return {
        for (final permission in permissions)
          permission: permission_handler.PermissionStatus.granted,
      };
    }
    return await permissions.request();
  }
}
