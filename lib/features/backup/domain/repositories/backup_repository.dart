/// 文件输入：立即备份资源列表
/// 文件职责：定义备份模块仓库接口，负责编排立即备份任务
/// 文件对外接口：BackupRepository
/// 文件包含：BackupRepository
import '../../../../core/result/app_result.dart';
import '../entities/backup_preparation_progress.dart';
import '../entities/backup_plan_entity.dart';
import '../entities/backup_run_record_entity.dart';
import '../entities/backup_run_result.dart';
import '../entities/backup_upload_request.dart';
import '../entities/backup_preparation_progress.dart';
import '../backup_run_cancellation.dart';

abstract class BackupRepository {
  Future<AppResult<List<BackupPlanEntity>>> loadPlans();
  Future<AppResult<List<BackupRunRecordEntity>>> loadRecentRuns({
    String? planId,
    int limit = 10,
    bool onlyAbnormal = false,
  });
  Future<AppResult<BackupPlanEntity>> createPlan(BackupPlanEntity plan);
  Future<AppResult<void>> togglePlan(String planId, bool enabled);
  /// [runId] / [planId] / [triggerType] 供进程内定时备份（Windows）使用；
  /// 手动备份保持默认值（自动生成 manual-* 运行记录）。
  Future<AppResult<BackupRunResult>> runBackupNow(
    List<BackupUploadRequest> requests, {
    void Function(BackupPreparationProgress progress)? onProgress,
    BackupRunCancellation? cancellation,
    String? runId,
    String? planId,
    String triggerType = 'manual',
  });
  Future<AppResult<void>> completeRun({
    required String runId,
    required String status,
    required int scannedCount,
    required int queuedCount,
    required int skippedCount,
    required int failedCount,
    String? errorMessage,
  });
}
