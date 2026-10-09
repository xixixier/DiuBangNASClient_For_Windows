/// 文件职责：Windows 桌面端通用 UI 组件与小工具
///   - DesktopPageHeader：页面顶部标题栏（标题 + 右侧操作区），替代移动端的大标题
///   - DesktopContent：限制内容最大宽度，避免宽屏下信息被拉得过散
///   - revealInExplorer / openWithShell：在资源管理器中定位文件、用系统默认程序打开
///   - formatBytes / formatDateTime：列表视图里的大小、日期格式
import 'dart:io';

import 'package:flutter/material.dart';

class DesktopTokens {
  DesktopTokens._();

  static const Color background = Color(0xFFF5F4F1);
  static const Color surface = Colors.white;
  static const Color border = Color(0xFFE6E4DF);
  static const Color hover = Color(0xFFEFEDE8);
  static const Color selected = Color(0xFFE3F0E7);
  static const Color selectedBorder = Color(0xFF3D8A5A);
  static const Color textPrimary = Color(0xFF1A1918);
  static const Color textSecondary = Color(0xFF6D6C6A);
  static const Color textTertiary = Color(0xFF9C9B99);
  static const Color danger = Color(0xFFB64848);

  static const double headerHeight = 60;
  static const double pagePadding = 24;
  static const double contentMaxWidth = 1180;
}

/// 页面顶部标题栏：左侧标题（可带副标题），右侧操作按钮。高度固定，不随内容滚动。
class DesktopPageHeader extends StatelessWidget {
  const DesktopPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: DesktopTokens.headerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: DesktopTokens.pagePadding,
        ),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: DesktopTokens.textPrimary,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    color: DesktopTokens.textSecondary,
                  ),
                ),
              ),
            ],
            const Spacer(),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// 限制内容最大宽度并靠左上对齐（与 Windows 设置应用一致）。
class DesktopContent extends StatelessWidget {
  const DesktopContent({
    super.key,
    required this.child,
    this.maxWidth = DesktopTokens.contentMaxWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// 在资源管理器中选中某个文件；若是目录则直接打开该目录。
Future<void> revealInExplorer(String path) async {
  if (!Platform.isWindows) {
    return;
  }
  try {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      await Process.start('explorer.exe', [path]);
      return;
    }
    await Process.start('explorer.exe', ['/select,', path]);
  } catch (_) {}
}

/// 用系统默认程序打开文件。
Future<void> openWithShell(String path) async {
  if (!Platform.isWindows) {
    return;
  }
  try {
    await Process.start('cmd', ['/c', 'start', '', path], runInShell: false);
  } catch (_) {}
}

String formatBytes(int bytes) {
  if (bytes < 0) return '--';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes < 1024 * 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  return '${(bytes / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(2)} TB';
}

String formatDateTime(DateTime? value) {
  if (value == null) return '--';
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}/${two(local.month)}/${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// 带悬停提示的紧凑图标按钮（工具栏用）。
class ToolbarIconButton extends StatelessWidget {
  const ToolbarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        style: IconButton.styleFrom(
          minimumSize: const Size(36, 36),
          fixedSize: const Size(36, 36),
          padding: EdgeInsets.zero,
          foregroundColor: selected ? primary : DesktopTokens.textSecondary,
          backgroundColor: selected
              ? DesktopTokens.selected
              : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}
