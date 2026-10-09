/// 文件输入：备份计划配置、Windows 备份文件夹、当前登录会话、传输队列
/// 文件职责：Windows 端进程内定时备份调度器（替代 Android 原生 WorkManager/AlarmManager
///   + BackupExecutionWorker）。应用在前台或最小化到托盘时，每 30 秒检查一次到期计划，
///   扫描用户选择的文件夹并复用 BackupRepository 的预检/去重/上传逻辑执行备份。
///   对外实现与 Android MethodChannel 相同的方法名与返回结构（见 BackupSchedulerBridge）。
/// 文件对外接口：WindowsBackupSchedulerBridge
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/device/desktop_media_files.dart';
import '../../../../core/device/local_media_picker.dart';
import '../../../../core/session/current_session.dart';
import '../../../transfer/domain/entities/transfer_direction.dart';
import '../../../transfer/domain/entities/transfer_status.dart';
import '../../../transfer/domain/entities/transfer_task_entity.dart';
import '../../../transfer/domain/entities/upload_conflict_resolution.dart';
import '../../../transfer/domain/repositories/transfer_repository.dart';
import '../../data/datasources/backup_local_data_source.dart';
import '../../data/windows_backup_folder_store.dart';
import '../../domain/backup_run_cancellation.dart';
import '../../domain/entities/backup_preparation_progress.dart';
import '../../domain/entities/backup_schedule_entity.dart';
import '../../domain/entities/backup_source_item.dart';
import '../../domain/entities/backup_source_type.dart';
import '../../domain/entities/backup_upload_request.dart';
import '../../domain/repositories/backup_repository.dart';
import 'backup_schedule_utils.dart';
import 'backup_scheduler_bridge.dart';

class WindowsBackupSchedulerBridge implements BackupSchedulerBridge {
  WindowsBackupSchedulerBridge({
    required SharedPreferences prefs,
    required BackupLocalDataSource localDataSource,
    required BackupRepository Function() backupRepositoryProvider,
    required TransferRepository Function() transferRepositoryProvider,
    required CurrentSession currentSession,
    required WindowsBackupFolderStore folderStore,
    Duration tickInterval = const Duration(seconds: 30),
  }) : _prefs = prefs,
       _localDataSource = localDataSource,
       _backupRepositoryProvider = backupRepositoryProvider,
       _transferRepositoryProvider = transferRepositoryProvider,
       _currentSession = currentSession,
       _folderStore = folderStore,
       _tickInterval = tickInterval;

  static const String _stateKey = 'windows_backup_scheduler_state_v1';
  static const int _maxRecentRuns = 5;

  final SharedPreferences _prefs;
  final BackupLocalDataSource _localDataSource;
  final BackupRepository Function() _backupRepositoryProvider;
  final TransferRepository Function() _transferRepositoryProvider;
  final CurrentSession _currentSession;
  final WindowsBackupFolderStore _folderStore;
  final Duration _tickInterval;

  final Map<String, _PlanState> _plans = <String, _PlanState>{};
  final List<Map<String, Object?>> _recentRuns = <Map<String, Object?>>[];
  Map<String, Object?>? _activeRun;
  BackupRunCancellation? _activeCancellation;
  final Set<String> _activeTaskIds = <String>{};
  Timer? _ticker;
  bool _started = false;
  bool _executing = false;

  /// 当前运行状态摘要，供托盘提示等桌面 UI 订阅（null 表示空闲）。
  final ValueNotifier<String?> statusMessage = ValueNotifier<String?>(null);

  @override
  bool get requiresNativeExecutionProfile => false;

  /// 应用启动时调用：恢复持久化的调度状态，清理上次退出时中断的运行，并启动定时检查。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _restoreState();
    try {
      await _localDataSource.markInterruptedRuns(
        errorMessage: '应用已退出，本次定时备份被中断',
      );
    } catch (error) {
      developer.log(
        'Failed to mark interrupted runs',
        name: 'backup.windows',
        error: error,
      );
    }
    _ticker = Timer.periodic(_tickInterval, (_) => unawaited(_tick()));
    // 启动后稍等片刻再检查，避免与登录/会话恢复抢资源
    Timer(const Duration(seconds: 20), () => unawaited(_tick()));
  }

  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    _activeCancellation?.cancel();
  }

  bool get hasActiveRun => _activeRun != null;

  // ---------------------------------------------------------------------------
  // BackupSchedulerBridge
  // ---------------------------------------------------------------------------

  @override
  Future<Map<String, Object?>?> invokeMapMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final args = arguments ?? const <String, Object?>{};
    switch (method) {
      case 'schedulePlan':
        return _schedulePlan(args);
      case 'cancelPlan':
        return _cancelPlan(args['planId']?.toString() ?? '');
      case 'getWorkerStateSnapshot':
        return _snapshot();
      case 'getScheduledBackupNotificationState':
        return const <String, Object?>{
          'runtimePermissionGranted': true,
          'appNotificationsEnabled': true,
          'channelEnabled': true,
          'message': 'Windows 端无需通知权限。定时备份需要应用保持运行（可最小化到系统托盘）。',
        };
      case 'getMediaAccessScope':
        return const <String, Object?>{'scope': 'full', 'message': ''};
      default:
        throw PlatformException(
          code: 'UNSUPPORTED',
          message: 'Windows 定时备份不支持方法 $method',
        );
    }
  }

  @override
  Future<void> invokeMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final args = arguments ?? const <String, Object?>{};
    switch (method) {
      case 'stopCurrentRun':
        await _stopCurrentRun(args['planId']?.toString());
        return;
      case 'cancelPlan':
        await _cancelPlan(args['planId']?.toString() ?? '');
        return;
      case 'openScheduledBackupNotificationSettings':
      case 'openBatteryOptimizationSettings':
      case 'openAutoStartSettings':
        return;
      default:
        throw PlatformException(
          code: 'UNSUPPORTED',
          message: 'Windows 定时备份不支持方法 $method',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // Schedule management
  // ---------------------------------------------------------------------------

  Map<String, Object?> _schedulePlan(Map<String, Object?> args) {
    final planId = args['planId']?.toString().trim() ?? '';
    if (planId.isEmpty) {
      throw PlatformException(code: 'INVALID_PLAN', message: '计划 ID 为空');
    }
    final schedule = _PlanState.scheduleFromArgs(args);
    final now = DateTime.now();
    final previous = _plans[planId];
    var nextRunAt = BackupScheduleUtils.nextRunAt(schedule, now: now);
    // 同一计划、同一时间规则重新注册（例如应用重启后的 syncPlans）时，保留尚未执行的
    // 到期时间，使电脑开机/应用启动后可以补跑当天错过的备份。
    final previousNext = previous?.nextRunAt;
    if (previous != null &&
        previousNext != null &&
        previous.scheduleStatus == 'scheduled' &&
        _PlanState.sameSchedule(previous.schedule, schedule) &&
        previousNext.isBefore(nextRunAt) &&
        !BackupScheduleUtils.shouldTreatRunAsMissed(
          schedule,
          previousNext,
          now: now,
        )) {
      nextRunAt = previousNext;
    }
    final state = _PlanState(
      planId: planId,
      planName: args['planName']?.toString() ?? '定时备份',
      serverId: args['serverId']?.toString(),
      schedule: schedule,
      includeImages: args['includeImages'] as bool? ?? true,
      includeVideos: args['includeVideos'] as bool? ?? true,
      scheduleStatus: 'scheduled',
      nextRunAt: nextRunAt,
      lastRunAt: previous?.lastRunAt,
      errorMessage: null,
    );
    _plans[planId] = state;
    _persistState();
    return <String, Object?>{
      'status': 'scheduled',
      'nextRunAtMillis': nextRunAt.millisecondsSinceEpoch,
    };
  }

  Map<String, Object?> _cancelPlan(String planId) {
    final removed = _plans.remove(planId);
    if (removed != null) {
      _persistState();
    }
    return const <String, Object?>{'status': 'unscheduled'};
  }

  Map<String, Object?> _snapshot() {
    final runs = <Map<String, Object?>>[
      ...?(_activeRun == null ? null : <Map<String, Object?>>[_activeRun!]),
      ..._recentRuns,
    ];
    return <String, Object?>{
      'plans': _plans.values.map((plan) => plan.toSnapshotMap()).toList(),
      'runs': runs.map((run) => Map<String, Object?>.from(run)).toList(),
    };
  }

  Future<void> _stopCurrentRun(String? planId) async {
    final active = _activeRun;
    if (active == null) {
      return;
    }
    if (planId != null && planId.isNotEmpty && active['planId'] != planId) {
      return;
    }
    _activeCancellation?.cancel();
    _updateActiveRun(status: 'stopping', progressMessage: '正在停止本次备份');
    final transferRepository = _transferRepositoryProvider();
    for (final taskId in _activeTaskIds.toList()) {
      try {
        await transferRepository.cancelTask(taskId);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  Future<void> _tick() async {
    if (_executing) return;
    final now = DateTime.now();
    _PlanState? due;
    for (final plan in _plans.values) {
      if (plan.scheduleStatus != 'scheduled') continue;
      final next = plan.nextRunAt;
      if (next != null && !next.isAfter(now)) {
        due = plan;
        break;
      }
    }
    if (due == null) return;

    // 开机自启后会话恢复需要时间：未登录时在 30 分钟宽限期内持续等待，超时才记为错过。
    final sessionReady =
        _currentSession.hasSession && _currentSession.writableRoots.isNotEmpty;
    if (!sessionReady &&
        now.difference(due.nextRunAt!) < const Duration(minutes: 30)) {
      return;
    }

    _executing = true;
    try {
      await _executePlan(due);
    } catch (error, stackTrace) {
      developer.log(
        'Scheduled backup crashed',
        name: 'backup.windows',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _executing = false;
      _advanceSchedule(due.planId);
    }
  }

  void _advanceSchedule(String planId) {
    final plan = _plans[planId];
    if (plan == null) return;
    if (BackupScheduleUtils.isRecurring(plan.schedule)) {
      plan.nextRunAt = BackupScheduleUtils.nextRunAt(
        plan.schedule,
        now: DateTime.now().add(const Duration(minutes: 1)),
      );
      plan.scheduleStatus = 'scheduled';
    } else {
      plan.nextRunAt = null;
      plan.scheduleStatus = 'unscheduled';
    }
    _persistState();
  }

  Future<void> _executePlan(_PlanState plan) async {
    final startedAt = DateTime.now();
    final runId = 'scheduled-${plan.planId}-${startedAt.microsecondsSinceEpoch}';
    final cancellation = BackupRunCancellation();
    _activeCancellation = cancellation;
    _activeTaskIds.clear();
    _activeRun = <String, Object?>{
      'id': runId,
      'planId': plan.planId,
      'triggerType': 'scheduled',
      'status': 'running',
      'scannedCount': 0,
      'queuedCount': 0,
      'skippedCount': 0,
      'failedCount': 0,
      'startedAtMillis': startedAt.millisecondsSinceEpoch,
      'progressMessage': '正在检查备份条件',
      'updatedAtMillis': startedAt.millisecondsSinceEpoch,
    };
    statusMessage.value = '正在执行定时备份';

    var recordInserted = false;
    Future<void> finishWithoutQueue({
      required String status,
      String? errorMessage,
      int scanned = 0,
    }) async {
      if (!recordInserted) {
        await _localDataSource.insertRun(
          runId: runId,
          planId: plan.planId,
          triggerType: 'scheduled',
          status: 'running',
          startedAt: startedAt,
        );
        recordInserted = true;
      }
      await _localDataSource.completeRun(
        runId: runId,
        status: status,
        scannedCount: scanned,
        queuedCount: 0,
        skippedCount: 0,
        failedCount: 0,
        finishedAt: DateTime.now(),
        errorMessage: errorMessage,
      );
      _finishActiveRun(status: status, errorMessage: errorMessage);
    }

    try {
      // 1. 前置条件
      final folders = _folderStore.loadFolders();
      if (folders.isEmpty) {
        await finishWithoutQueue(
          status: 'failed',
          errorMessage: '尚未选择备份文件夹，请在“文件备份”页添加文件夹',
        );
        return;
      }
      if (!_currentSession.hasSession || _currentSession.writableRoots.isEmpty) {
        await finishWithoutQueue(
          status: 'missed',
          errorMessage: '计划时间已到，但应用当前未登录服务器，本次定时备份已跳过',
        );
        return;
      }
      final planServerId = plan.serverId?.trim();
      final sessionServerId = _currentSession.serverId?.trim();
      final sessionServerUrl = _currentSession.serverUrl?.trim();
      if (planServerId != null &&
          planServerId.isNotEmpty &&
          planServerId != sessionServerId &&
          planServerId != sessionServerUrl) {
        await finishWithoutQueue(
          status: 'missed',
          errorMessage: '当前连接的服务器与计划绑定的服务器不一致，本次定时备份已跳过',
        );
        return;
      }
      if (plan.schedule.requiresWifi && !await _isOnLocalNetwork()) {
        await finishWithoutQueue(
          status: 'missed',
          errorMessage: '计划要求在 Wi-Fi / 有线网络下执行，当前网络不满足，本次已跳过',
        );
        return;
      }

      // 2. 扫描文件夹
      _updateActiveRun(progressMessage: '正在扫描备份文件夹');
      final files = await DesktopMediaFiles.scanFolders(
        folders,
        includeImages: plan.includeImages,
        includeVideos: plan.includeVideos,
        shouldCancel: () => cancellation.isCancelled,
        onProgress: (progress) {
          _updateActiveRun(
            scannedCount: progress.discoveredItems,
            progressMessage:
                '已扫描 ${progress.scannedEntries} 项，发现 ${progress.discoveredItems} 个可备份文件',
          );
        },
      );
      if (cancellation.isCancelled) {
        await finishWithoutQueue(
          status: 'stopped',
          errorMessage: '用户已停止本次备份',
          scanned: files.length,
        );
        return;
      }
      if (files.isEmpty) {
        await finishWithoutQueue(
          status: 'completed',
          errorMessage: null,
          scanned: 0,
        );
        return;
      }

      // 3. 预检 + 去重 + 入队（复用手动备份逻辑）
      final requests = files
          .map((file) => BackupUploadRequest.fromSource(backupSourceItemFor(file)))
          .toList(growable: false);
      _updateActiveRun(
        scannedCount: requests.length,
        totalCount: requests.length,
        processedCount: 0,
        progressMessage: '正在与服务端比对 ${requests.length} 个文件',
      );
      final result = await _backupRepositoryProvider().runBackupNow(
        requests,
        cancellation: cancellation,
        runId: runId,
        planId: plan.planId,
        triggerType: 'scheduled',
        onProgress: (progress) {
          _updateActiveRun(
            progressMessage: progress.detail ?? progress.phase.title,
          );
        },
      );
      recordInserted = true;

      if (result.isFailure) {
        final failure = result.failureOrNull!;
        final status = failure.code == 'BACKUP_RUN_CANCELLED'
            ? 'stopped'
            : 'failed';
        _finishActiveRun(status: status, errorMessage: failure.message);
        if (status != 'stopped') {
          plan.lastRunAt = startedAt;
        }
        return;
      }

      final runResult = result.dataOrNull!;
      final skipped = runResult.skippedCount;
      final failedToQueue = runResult.failedCount;
      if (!runResult.hasQueuedTasks) {
        // Repository 已写入完成记录
        final status = failedToQueue > 0 ? 'partial_failed' : 'completed';
        _finishActiveRun(
          status: status,
          errorMessage: runResult.failureMessages.isEmpty
              ? null
              : runResult.failureMessages.first,
          skippedCount: skipped,
          failedCount: failedToQueue,
          scannedCount: runResult.scannedCount,
        );
        plan.lastRunAt = startedAt;
        await _localDataSource.updatePlanLastRun(plan.planId, startedAt);
        return;
      }

      // 4. 等待上传任务完成
      final outcome = await _awaitUploads(
        runResult.queuedTaskIds,
        cancellation: cancellation,
        alreadyProcessed: skipped,
        total: requests.length,
      );
      final failedCount = failedToQueue + outcome.failed;
      final skippedCount = skipped + outcome.skipped;
      final String status;
      if (cancellation.isCancelled) {
        status = 'stopped';
      } else if (failedCount > 0) {
        status = (outcome.completed > 0 || skippedCount > 0)
            ? 'partial_failed'
            : 'failed';
      } else {
        status = 'completed';
      }
      final errorMessage = cancellation.isCancelled
          ? '用户已停止本次备份'
          : (outcome.firstError ??
                (runResult.failureMessages.isEmpty
                    ? null
                    : runResult.failureMessages.first));
      await _localDataSource.completeRun(
        runId: runId,
        status: status,
        scannedCount: runResult.scannedCount,
        queuedCount: outcome.completed,
        skippedCount: skippedCount,
        failedCount: failedCount,
        finishedAt: DateTime.now(),
        errorMessage: errorMessage,
      );
      _finishActiveRun(
        status: status,
        errorMessage: errorMessage,
        scannedCount: runResult.scannedCount,
        queuedCount: outcome.completed,
        skippedCount: skippedCount,
        failedCount: failedCount,
      );
      if (status != 'stopped') {
        plan.lastRunAt = startedAt;
        await _localDataSource.updatePlanLastRun(plan.planId, startedAt);
      }
    } catch (error) {
      try {
        await finishWithoutQueue(status: 'failed', errorMessage: '$error');
      } catch (_) {
        _finishActiveRun(status: 'failed', errorMessage: '$error');
      }
    } finally {
      _activeCancellation = null;
      _activeTaskIds.clear();
      statusMessage.value = null;
      _persistState();
    }
  }

  Future<_UploadOutcome> _awaitUploads(
    List<String> taskIds, {
    required BackupRunCancellation cancellation,
    required int alreadyProcessed,
    required int total,
  }) async {
    final transferRepository = _transferRepositoryProvider();
    final pending = taskIds.toSet();
    _activeTaskIds
      ..clear()
      ..addAll(pending);
    final statuses = <String, TransferTaskEntity>{};
    final resolvingConflicts = <String>{};
    final completer = Completer<void>();

    bool isTerminal(TransferStatus status) => switch (status) {
      TransferStatus.completed ||
      TransferStatus.skipped ||
      TransferStatus.failed ||
      TransferStatus.cancelled => true,
      _ => false,
    };

    void evaluate() {
      var completed = 0;
      var terminal = 0;
      String? activeName;
      for (final id in pending) {
        final task = statuses[id];
        if (task == null) continue;
        if (isTerminal(task.status)) {
          terminal += 1;
          if (task.status == TransferStatus.completed) completed += 1;
        } else {
          activeName ??= task.fileName;
          if (task.status == TransferStatus.awaitingConflictResolution &&
              resolvingConflicts.add(id)) {
            unawaited(
              transferRepository
                  .resolveUploadConflict(
                    taskId: id,
                    resolution: UploadConflictResolution.autoRename,
                  )
                  .whenComplete(() => resolvingConflicts.remove(id)),
            );
          }
        }
      }
      _updateActiveRun(
        processedCount: (alreadyProcessed + terminal).clamp(0, total),
        totalCount: total,
        queuedCount: completed,
        progressMessage: activeName == null
            ? '已完成 $terminal / ${pending.length} 个上传任务'
            : '正在上传 $activeName（$terminal / ${pending.length}）',
      );
      if (terminal >= pending.length && !completer.isCompleted) {
        completer.complete();
      }
    }

    final subscription = transferRepository.taskStream.listen((task) {
      if (!pending.contains(task.id)) return;
      statuses[task.id] = task;
      evaluate();
    });

    // 兜底：定期全量拉取任务状态（防止漏掉事件）
    final poller = Timer.periodic(const Duration(seconds: 5), (_) async {
      final loaded = await transferRepository.loadTasks();
      final tasks = loaded.dataOrNull;
      if (tasks == null) return;
      for (final task in tasks) {
        if (pending.contains(task.id)) {
          statuses[task.id] = task;
        }
      }
      // 任务被清理（不在列表中）视为已结束
      for (final id in pending) {
        if (!tasks.any((task) => task.id == id) && !statuses.containsKey(id)) {
          statuses[id] = _syntheticTerminal(id);
        }
      }
      if (cancellation.isCancelled) {
        for (final id in pending) {
          final task = statuses[id];
          if (task != null && !isTerminal(task.status)) {
            unawaited(transferRepository.cancelTask(id));
          }
        }
      }
      evaluate();
    });

    try {
      final initial = await transferRepository.loadTasks();
      for (final task in initial.dataOrNull ?? const <TransferTaskEntity>[]) {
        if (pending.contains(task.id)) {
          statuses[task.id] = task;
        }
      }
      evaluate();
      await completer.future;
    } finally {
      poller.cancel();
      await subscription.cancel();
    }

    var completed = 0;
    var failed = 0;
    var skipped = 0;
    String? firstError;
    for (final id in pending) {
      final task = statuses[id];
      switch (task?.status) {
        case TransferStatus.completed:
          completed += 1;
        case TransferStatus.skipped:
          skipped += 1;
        case TransferStatus.failed:
        case TransferStatus.cancelled:
          failed += 1;
          firstError ??= task?.errorMessage;
        default:
          break;
      }
    }
    return _UploadOutcome(
      completed: completed,
      failed: failed,
      skipped: skipped,
      firstError: firstError,
    );
  }

  TransferTaskEntity _syntheticTerminal(String id) {
    return TransferTaskEntity(
      id: id,
      rootId: '',
      localPath: '',
      remotePath: '',
      fileName: '',
      totalBytes: 0,
      transferredBytes: 0,
      direction: TransferDirection.upload,
      status: TransferStatus.completed,
      createdAt: DateTime.now(),
    );
  }

  Future<bool> _isOnLocalNetwork() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return true;
    }
  }

  /// 把扫描到的文件夹文件转换为备份资源。手动“备份文件夹”与定时备份使用同一 ID
  /// 规则（file:<规范化小写路径>），保证本地去重缓存共享。
  static BackupSourceItem backupSourceItemFor(DesktopMediaFile file) {
    return BackupSourceItem(
      id: 'file:${file.stableId}',
      sourceType: BackupSourceType.directoryExpandedFile,
      localPath: file.path,
      displayName: file.displayName,
      size: file.size,
      mimeType: guessMimeTypeFromFileName(file.displayName),
      sourceLabel: '来自文件夹 ${file.rootFolder}',
      createdAt: file.modifiedAt,
      modifiedAt: file.modifiedAt,
    );
  }

  // ---------------------------------------------------------------------------
  // Run snapshot helpers
  // ---------------------------------------------------------------------------

  void _updateActiveRun({
    String? status,
    String? progressMessage,
    int? scannedCount,
    int? queuedCount,
    int? processedCount,
    int? totalCount,
  }) {
    final run = _activeRun;
    if (run == null) return;
    if (status != null) run['status'] = status;
    if (progressMessage != null) run['progressMessage'] = progressMessage;
    if (scannedCount != null) run['scannedCount'] = scannedCount;
    if (queuedCount != null) run['queuedCount'] = queuedCount;
    if (processedCount != null) run['processedCount'] = processedCount;
    if (totalCount != null) run['totalCount'] = totalCount;
    run['updatedAtMillis'] = DateTime.now().millisecondsSinceEpoch;
    if (progressMessage != null) {
      statusMessage.value = progressMessage;
    }
  }

  void _finishActiveRun({
    required String status,
    String? errorMessage,
    int? scannedCount,
    int? queuedCount,
    int? skippedCount,
    int? failedCount,
  }) {
    final run = _activeRun;
    if (run == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    run
      ..['status'] = status
      ..['finishedAtMillis'] = now
      ..['updatedAtMillis'] = now
      ..['errorMessage'] = errorMessage
      ..remove('progressMessage');
    if (scannedCount != null) run['scannedCount'] = scannedCount;
    if (queuedCount != null) run['queuedCount'] = queuedCount;
    if (skippedCount != null) run['skippedCount'] = skippedCount;
    if (failedCount != null) run['failedCount'] = failedCount;
    _recentRuns.insert(0, run);
    while (_recentRuns.length > _maxRecentRuns) {
      _recentRuns.removeLast();
    }
    _activeRun = null;
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  void _restoreState() {
    final raw = _prefs.getString(_stateKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final plans = decoded['plans'];
      if (plans is List) {
        for (final entry in plans) {
          if (entry is Map) {
            final state = _PlanState.fromJson(
              entry.map((key, value) => MapEntry('$key', value)),
            );
            if (state != null) {
              _plans[state.planId] = state;
            }
          }
        }
      }
    } catch (error) {
      developer.log(
        'Failed to restore scheduler state',
        name: 'backup.windows',
        error: error,
      );
    }
  }

  void _persistState() {
    final payload = jsonEncode(<String, Object?>{
      'plans': _plans.values.map((plan) => plan.toJson()).toList(),
    });
    unawaited(_prefs.setString(_stateKey, payload));
  }
}

class _UploadOutcome {
  const _UploadOutcome({
    required this.completed,
    required this.failed,
    required this.skipped,
    this.firstError,
  });

  final int completed;
  final int failed;
  final int skipped;
  final String? firstError;
}

class _PlanState {
  _PlanState({
    required this.planId,
    required this.planName,
    required this.serverId,
    required this.schedule,
    required this.includeImages,
    required this.includeVideos,
    required this.scheduleStatus,
    required this.nextRunAt,
    required this.lastRunAt,
    required this.errorMessage,
  });

  final String planId;
  final String planName;
  final String? serverId;
  final BackupScheduleEntity schedule;
  final bool includeImages;
  final bool includeVideos;
  String scheduleStatus;
  DateTime? nextRunAt;
  DateTime? lastRunAt;
  String? errorMessage;

  static bool sameSchedule(BackupScheduleEntity a, BackupScheduleEntity b) {
    return a.type == b.type &&
        a.hour == b.hour &&
        a.minute == b.minute &&
        a.weekday == b.weekday &&
        a.dayOfMonth == b.dayOfMonth &&
        a.onceAt?.millisecondsSinceEpoch == b.onceAt?.millisecondsSinceEpoch;
  }

  static BackupScheduleEntity scheduleFromArgs(Map<String, Object?> args) {
    final typeName = args['scheduleType']?.toString() ?? 'daily';
    final type = BackupScheduleType.values.firstWhere(
      (value) => value.name == typeName,
      orElse: () => BackupScheduleType.daily,
    );
    final onceAtMillis = _asInt(args['onceAtMillis']);
    return BackupScheduleEntity(
      type: type,
      hour: _asInt(args['hour']) ?? 2,
      minute: _asInt(args['minute']) ?? 0,
      weekday: _asInt(args['weekday']),
      dayOfMonth: _asInt(args['dayOfMonth']),
      onceAt: onceAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(onceAtMillis),
      requiresWifi: args['requiresWifi'] as bool? ?? false,
      requiresCharging: args['requiresCharging'] as bool? ?? false,
    );
  }

  Map<String, Object?> toSnapshotMap() => <String, Object?>{
    'planId': planId,
    'enabled': true,
    'scheduleStatus': scheduleStatus,
    'lastRunAtMillis': lastRunAt?.millisecondsSinceEpoch,
    'scheduledRunAtMillis': nextRunAt?.millisecondsSinceEpoch,
    'scheduleErrorMessage': errorMessage,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'planId': planId,
    'planName': planName,
    'serverId': serverId,
    'scheduleType': schedule.type.name,
    'hour': schedule.hour,
    'minute': schedule.minute,
    'weekday': schedule.weekday,
    'dayOfMonth': schedule.dayOfMonth,
    'onceAtMillis': schedule.onceAt?.millisecondsSinceEpoch,
    'requiresWifi': schedule.requiresWifi,
    'requiresCharging': schedule.requiresCharging,
    'includeImages': includeImages,
    'includeVideos': includeVideos,
    'scheduleStatus': scheduleStatus,
    'nextRunAtMillis': nextRunAt?.millisecondsSinceEpoch,
    'lastRunAtMillis': lastRunAt?.millisecondsSinceEpoch,
    'errorMessage': errorMessage,
  };

  static _PlanState? fromJson(Map<String, Object?> json) {
    final planId = json['planId']?.toString() ?? '';
    if (planId.isEmpty) return null;
    final next = _asInt(json['nextRunAtMillis']);
    final last = _asInt(json['lastRunAtMillis']);
    return _PlanState(
      planId: planId,
      planName: json['planName']?.toString() ?? '定时备份',
      serverId: json['serverId']?.toString(),
      schedule: scheduleFromArgs(json),
      includeImages: json['includeImages'] as bool? ?? true,
      includeVideos: json['includeVideos'] as bool? ?? true,
      scheduleStatus: json['scheduleStatus']?.toString() ?? 'scheduled',
      nextRunAt: next == null ? null : DateTime.fromMillisecondsSinceEpoch(next),
      lastRunAt: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
      errorMessage: json['errorMessage']?.toString(),
    );
  }

  static int? _asInt(Object? value) => switch (value) {
    int v => v,
    num v => v.toInt(),
    String v => int.tryParse(v),
    _ => null,
  };
}
