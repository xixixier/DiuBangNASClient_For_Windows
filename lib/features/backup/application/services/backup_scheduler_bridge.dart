/// 文件输入：方法名 + 参数
/// 文件职责：抽象“定时备份调度后端”。Android 使用原生 WorkManager/AlarmManager
///   （MethodChannel `com.nasclient/backup_scheduler`）；Windows 使用进程内 Dart 调度器。
///   两者遵循同一套方法名与返回 Map 结构，BackupPlanSchedulerService 无需关心平台。
/// 文件对外接口：BackupSchedulerBridge、MethodChannelBackupSchedulerBridge
import 'package:flutter/services.dart';

abstract class BackupSchedulerBridge {
  /// true：schedulePlan 需要完整的原生执行配置（令牌、证书等，Android 后台 Worker 使用）。
  /// false：调度在进程内执行，直接复用当前登录会话。
  bool get requiresNativeExecutionProfile;

  Future<Map<String, Object?>?> invokeMapMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]);

  Future<void> invokeMethod(String method, [Map<String, Object?>? arguments]);
}

class MethodChannelBackupSchedulerBridge implements BackupSchedulerBridge {
  MethodChannelBackupSchedulerBridge(this._channel);

  final MethodChannel _channel;

  @override
  bool get requiresNativeExecutionProfile => true;

  @override
  Future<Map<String, Object?>?> invokeMapMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) {
    return _channel.invokeMapMethod<String, Object?>(method, arguments);
  }

  @override
  Future<void> invokeMethod(String method, [Map<String, Object?>? arguments]) {
    return _channel.invokeMethod<void>(method, arguments);
  }
}
