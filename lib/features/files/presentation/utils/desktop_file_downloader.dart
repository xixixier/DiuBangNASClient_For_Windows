/// 文件职责：Windows 桌面端批量下载
///   - 「下载」：先下到应用暂存目录，完成后转存到 图片\铥棒文件 或 下载\铥棒文件，并删除暂存文件
///   - 「下载到…」：直接写入用户选择的文件夹（同名自动加序号）
///   全部任务结束后弹出汇总提示，并提供「在文件夹中显示」。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;

import '../../../../app/di/service_locator.dart';
import '../../../../core/desktop/desktop_ui.dart';
import '../../../preview/application/params/save_original_to_public_storage_params.dart';
import '../../../transfer/domain/entities/transfer_status.dart';
import '../../../transfer/presentation/cubit/transfer_cubit.dart';
import '../../../transfer/presentation/cubit/transfer_state.dart';
import '../../application/params/build_file_browser_download_path_params.dart';
import '../../domain/entities/file_entry_entity.dart';

class _PendingDownload {
  _PendingDownload({
    required this.file,
    required this.localPath,
    required this.staged,
  });

  final FileEntryEntity file;
  final String localPath;
  final bool staged;
  bool finished = false;
}

class DesktopFileDownloader {
  const DesktopFileDownloader._();

  static Future<void> download(
    BuildContext context, {
    required List<FileEntryEntity> files,
    required String rootId,
    String? targetDirectory,
    bool openWhenDone = false,
  }) async {
    final downloadable = files.where((f) => f.isFile).toList(growable: false);
    if (downloadable.isEmpty) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final transferCubit = context.read<TransferCubit>();
    final pending = <String, _PendingDownload>{};
    var enqueueFailed = 0;

    for (final file in downloadable) {
      try {
        final String localPath;
        final bool staged;
        if (targetDirectory != null && targetDirectory.isNotEmpty) {
          localPath = _uniqueTarget(targetDirectory, file.name);
          staged = false;
        } else {
          localPath = await serviceLocator.buildFileBrowserDownloadPathUseCase
              .call(BuildFileBrowserDownloadPathParams(fileName: file.name));
          staged = true;
        }
        final task = await transferCubit.enqueueDownload(
          remotePath: file.path,
          localPath: localPath,
          rootId: rootId,
        );
        if (task == null) {
          enqueueFailed += 1;
          continue;
        }
        pending[task.id] = _PendingDownload(
          file: file,
          localPath: localPath,
          staged: staged,
        );
      } catch (_) {
        enqueueFailed += 1;
      }
    }

    if (pending.isEmpty) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('添加下载任务失败')));
      return;
    }

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            pending.length == 1
                ? '${openWhenDone ? '正在下载并打开' : '开始下载'}：${pending.values.first.file.name}'
                : '已加入下载队列：${pending.length} 个文件',
          ),
          duration: const Duration(seconds: 2),
        ),
      );

    final savedPaths = <String>[];
    var failed = enqueueFailed;
    late final StreamSubscription<TransferState> subscription;
    var finalizing = 0;

    Future<void> finishOne(_PendingDownload item, TransferStatus status) async {
      item.finished = true;
      if (status == TransferStatus.completed) {
        if (item.staged) {
          finalizing += 1;
          final result = await serviceLocator.saveOriginalToPublicStorageUseCase
              .call(
                SaveOriginalToPublicStorageParams(
                  localPath: item.localPath,
                  fileName: item.file.name,
                ),
              );
          result.when(
            success: (savedPath) {
              savedPaths.add(savedPath);
              try {
                final staging = File(item.localPath);
                if (staging.existsSync() &&
                    !p.equals(staging.absolute.path, savedPath)) {
                  staging.deleteSync();
                }
              } catch (_) {}
            },
            failure: (_) => savedPaths.add(item.localPath),
          );
          finalizing -= 1;
        } else {
          savedPaths.add(item.localPath);
        }
      } else {
        failed += 1;
      }
    }

    void maybeReport() {
      if (finalizing > 0 || pending.values.any((item) => !item.finished)) {
        return;
      }
      unawaited(subscription.cancel());
      if (openWhenDone && savedPaths.length == 1 && failed == 0) {
        unawaited(openWithShell(savedPaths.first));
      }
      final String message;
      if (savedPaths.isEmpty) {
        message = '下载失败';
      } else if (failed == 0) {
        message = savedPaths.length == 1
            ? '已下载到 ${savedPaths.first}'
            : '已下载 ${savedPaths.length} 个文件到 ${p.dirname(savedPaths.last)}';
      } else {
        message = '已下载 ${savedPaths.length} 个，失败 $failed 个';
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 6),
            action: savedPaths.isEmpty
                ? null
                : SnackBarAction(
                    label: '在文件夹中显示',
                    onPressed: () => revealInExplorer(savedPaths.last),
                  ),
          ),
        );
    }

    Future<void> onState(TransferState state) async {
      if (state is! TransferLoaded) {
        return;
      }
      for (final task in state.tasks) {
        final item = pending[task.id];
        if (item == null || item.finished) {
          continue;
        }
        switch (task.status) {
          case TransferStatus.completed:
          case TransferStatus.failed:
          case TransferStatus.cancelled:
          case TransferStatus.skipped:
            await finishOne(item, task.status);
          default:
            break;
        }
      }
      maybeReport();
    }

    subscription = transferCubit.stream.listen((state) {
      unawaited(onState(state));
    });
    unawaited(onState(transferCubit.state));
  }

  static String _uniqueTarget(String directory, String fileName) {
    final sanitized = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_');
    var candidate = p.join(directory, sanitized);
    if (!File(candidate).existsSync()) {
      return candidate;
    }
    final base = p.basenameWithoutExtension(sanitized);
    final ext = p.extension(sanitized);
    for (var i = 1; i < 1000; i++) {
      candidate = p.join(directory, '$base ($i)$ext');
      if (!File(candidate).existsSync()) {
        return candidate;
      }
    }
    return candidate;
  }
}
