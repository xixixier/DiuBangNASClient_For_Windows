/// 文件职责：Windows 桌面端右侧「传输」面板
///   显示上传/下载队列、进度、暂停/继续/取消、在文件夹中显示、清除已完成。
///   面板开关由 DesktopShellState.transferPanelOpen 控制（侧栏按钮、文件页状态栏都能打开）。
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/desktop/desktop_ui.dart';
import '../../domain/entities/transfer_direction.dart';
import '../../domain/entities/transfer_status.dart';
import '../../domain/entities/transfer_task_entity.dart';
import '../cubit/transfer_cubit.dart';
import '../cubit/transfer_state.dart';

class DesktopShellState {
  DesktopShellState._();

  static final ValueNotifier<bool> transferPanelOpen = ValueNotifier<bool>(
    false,
  );

  static void toggleTransferPanel() {
    transferPanelOpen.value = !transferPanelOpen.value;
  }
}

bool isActiveTransfer(TransferTaskEntity task) =>
    task.status == TransferStatus.pending ||
    task.status == TransferStatus.transferring ||
    task.status == TransferStatus.paused ||
    task.status == TransferStatus.awaitingConflictResolution;

class DesktopTransferPanel extends StatefulWidget {
  const DesktopTransferPanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<DesktopTransferPanel> createState() => _DesktopTransferPanelState();
}

enum _TransferFilter { active, finished }

class _DesktopTransferPanelState extends State<DesktopTransferPanel> {
  _TransferFilter _filter = _TransferFilter.active;

  @override
  void initState() {
    super.initState();
    final cubit = context.read<TransferCubit>();
    if (cubit.state is TransferInitial) {
      cubit.loadTasks();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: Container(
        width: 360,
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: DesktopTokens.border)),
        ),
        child: BlocBuilder<TransferCubit, TransferState>(
          builder: (context, state) {
            final tasks = state is TransferLoaded
                ? state.tasks
                : const <TransferTaskEntity>[];
            final active = tasks.where(isActiveTransfer).toList();
            final finished = tasks.where((t) => !isActiveTransfer(t)).toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            final shown = _filter == _TransferFilter.active ? active : finished;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: DesktopTokens.headerHeight,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 18, right: 8),
                    child: Row(
                      children: [
                        const Text(
                          '传输',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: DesktopTokens.textPrimary,
                          ),
                        ),
                        const Spacer(),
                        if (_filter == _TransferFilter.finished &&
                            finished.isNotEmpty)
                          TextButton(
                            onPressed: () =>
                                context.read<TransferCubit>().clearCompleted(),
                            child: const Text('清除记录'),
                          ),
                        ToolbarIconButton(
                          icon: Icons.close_rounded,
                          tooltip: '关闭',
                          onPressed: widget.onClose,
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: SegmentedButton<_TransferFilter>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: [
                      ButtonSegment(
                        value: _TransferFilter.active,
                        label: Text('进行中 (${active.length})'),
                      ),
                      ButtonSegment(
                        value: _TransferFilter.finished,
                        label: Text('已结束 (${finished.length})'),
                      ),
                    ],
                    selected: {_filter},
                    onSelectionChanged: (value) =>
                        setState(() => _filter = value.first),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Text(
                            _filter == _TransferFilter.active
                                ? '没有正在进行的传输'
                                : '暂无传输记录',
                            style: const TextStyle(
                              color: DesktopTokens.textTertiary,
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                          itemCount: shown.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 2),
                          itemBuilder: (context, index) =>
                              _TransferRow(task: shown[index]),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TransferRow extends StatefulWidget {
  const _TransferRow({required this.task});

  final TransferTaskEntity task;

  @override
  State<_TransferRow> createState() => _TransferRowState();
}

class _TransferRowState extends State<_TransferRow> {
  bool _hovered = false;

  String _statusText(TransferTaskEntity task) {
    switch (task.status) {
      case TransferStatus.pending:
        return '等待中';
      case TransferStatus.paused:
        return '已暂停 · ${task.formattedTransferred} / ${task.formattedSize}';
      case TransferStatus.transferring:
        return '${(task.progress * 100).toStringAsFixed(0)}% · '
            '${task.formattedTransferred} / ${task.formattedSize}';
      case TransferStatus.awaitingConflictResolution:
        return '存在同名文件，等待处理';
      case TransferStatus.completed:
        return '已完成 · ${task.formattedSize}';
      case TransferStatus.skipped:
        return '已跳过';
      case TransferStatus.failed:
        return task.errorMessage == null || task.errorMessage!.isEmpty
            ? '失败'
            : '失败：${task.errorMessage}';
      case TransferStatus.cancelled:
        return '已取消';
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final cubit = context.read<TransferCubit>();
    final isUpload = task.direction == TransferDirection.upload;
    final failed = task.status == TransferStatus.failed;
    final showProgress =
        task.status == TransferStatus.transferring ||
        task.status == TransferStatus.paused;

    final actions = <Widget>[
      if (task.status == TransferStatus.transferring ||
          task.status == TransferStatus.pending)
        ToolbarIconButton(
          icon: Icons.pause_rounded,
          tooltip: '暂停',
          onPressed: () => cubit.pauseTask(task.id),
        ),
      if (task.status == TransferStatus.paused)
        ToolbarIconButton(
          icon: Icons.play_arrow_rounded,
          tooltip: '继续',
          onPressed: () => cubit.resumeTask(task.id),
        ),
      if (isActiveTransfer(task))
        ToolbarIconButton(
          icon: Icons.close_rounded,
          tooltip: '取消',
          onPressed: () => cubit.cancelTask(task.id),
        ),
      if (!isUpload &&
          task.status == TransferStatus.completed &&
          task.localPath.isNotEmpty)
        ToolbarIconButton(
          icon: Icons.folder_open_outlined,
          tooltip: '在文件夹中显示',
          onPressed: () => revealInExplorer(task.localPath),
        ),
    ];

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          color: _hovered ? DesktopTokens.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              isUpload ? Icons.upload_rounded : Icons.download_rounded,
              size: 20,
              color: failed
                  ? DesktopTokens.danger
                  : Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: task.remotePath,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(
                      task.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: DesktopTokens.textPrimary,
                      ),
                    ),
                  ),
                  if (showProgress) ...[
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: task.progress.clamp(0, 1).toDouble(),
                        minHeight: 3,
                        backgroundColor: const Color(0xFFE8F3EB),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    _statusText(task),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: failed
                          ? DesktopTokens.danger
                          : DesktopTokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (actions.isNotEmpty) ...[const SizedBox(width: 4), ...actions],
          ],
        ),
      ),
    );
  }
}
