/// 文件职责：Windows 桌面端文件浏览组件
///   - DesktopFileGridTile：网格视图的一格（缩略图 + 文件名，悬停/选中态）
///   - DesktopFileListRow / DesktopFileListHeader：详细信息列表视图
///   - DesktopSegmented：紧凑分段切换（分类、共享/原机）
///   - fileIconFor / fileTypeLabel：文件图标与类型名
///   鼠标交互（单击/双击/右键）由页面统一处理，这里只负责显示。
import 'dart:typed_data';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/desktop/desktop_ui.dart';
import '../../domain/entities/file_entry_entity.dart';

IconData fileIconFor(FileEntryEntity file) {
  if (file.isDirectory) return Icons.folder_rounded;
  switch (file.extension) {
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'gif':
    case 'bmp':
    case 'webp':
      return Icons.image_outlined;
    case 'mp4':
    case 'avi':
    case 'mkv':
    case 'mov':
    case 'webm':
    case '3gp':
      return Icons.movie_outlined;
    case 'mp3':
    case 'wav':
    case 'flac':
    case 'aac':
    case 'ogg':
      return Icons.audio_file_outlined;
    case 'pdf':
      return Icons.picture_as_pdf_outlined;
    case 'doc':
    case 'docx':
      return Icons.article_outlined;
    case 'xls':
    case 'xlsx':
    case 'csv':
      return Icons.grid_on_outlined;
    case 'ppt':
    case 'pptx':
      return Icons.slideshow_outlined;
    case 'zip':
    case 'rar':
    case '7z':
    case 'tar':
    case 'gz':
      return Icons.folder_zip_outlined;
    case 'txt':
    case 'md':
    case 'log':
      return Icons.text_snippet_outlined;
    case 'apk':
      return Icons.android;
    case 'exe':
    case 'msi':
      return Icons.terminal;
    default:
      return Icons.insert_drive_file_outlined;
  }
}

Color fileIconColor(FileEntryEntity file) {
  if (file.isDirectory) return const Color(0xFF3D8A5A);
  if (file.isImage) return const Color(0xFF9B7A48);
  if (file.isVideo) return const Color(0xFF5777A8);
  switch (file.extension) {
    case 'pdf':
    case 'doc':
    case 'docx':
    case 'xls':
    case 'xlsx':
    case 'ppt':
    case 'pptx':
      return const Color(0xFFB5664C);
    default:
      return const Color(0xFF7C7974);
  }
}

String fileTypeLabel(FileEntryEntity file) {
  if (file.isDirectory) return '文件夹';
  final ext = file.extension;
  if (ext.isEmpty) return '文件';
  if (file.isImage) return '${ext.toUpperCase()} 图片';
  if (file.isVideo) return '${ext.toUpperCase()} 视频';
  return '${ext.toUpperCase()} 文件';
}

class _ThumbnailOrIcon extends StatelessWidget {
  const _ThumbnailOrIcon({
    required this.file,
    required this.getThumbnail,
    required this.watchThumbnail,
    required this.iconSize,
  });

  final FileEntryEntity file;
  final Uint8List? Function(String filePath) getThumbnail;
  final Stream<void> Function(String filePath) watchThumbnail;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final isMedia = file.isImage || file.isVideo;
    Widget icon() => Center(
      child: Icon(
        fileIconFor(file),
        size: iconSize,
        color: fileIconColor(file),
      ),
    );
    if (!isMedia) {
      return icon();
    }
    return StreamBuilder<void>(
      stream: watchThumbnail(file.path),
      builder: (context, _) {
        final data = getThumbnail(file.path);
        if (data == null) {
          return icon();
        }
        return ExtendedImage.memory(
          data,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          enableLoadState: false,
          filterQuality: FilterQuality.medium,
          loadStateChanged: (state) {
            if (state.extendedImageLoadState == LoadState.failed) {
              return icon();
            }
            return null;
          },
        );
      },
    );
  }
}

class DesktopFileGridTile extends StatefulWidget {
  const DesktopFileGridTile({
    super.key,
    required this.file,
    required this.selected,
    required this.getThumbnail,
    required this.watchThumbnail,
  });

  final FileEntryEntity file;
  final bool selected;
  final Uint8List? Function(String filePath) getThumbnail;
  final Stream<void> Function(String filePath) watchThumbnail;

  static const double nameAreaHeight = 40;

  @override
  State<DesktopFileGridTile> createState() => _DesktopFileGridTileState();
}

class _DesktopFileGridTileState extends State<DesktopFileGridTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final selected = widget.selected;
    final background = selected
        ? DesktopTokens.selected
        : _hovered
        ? DesktopTokens.hover
        : Colors.transparent;
    final tooltip = [
      file.name,
      if (file.isFile) '大小：${file.formattedSize}',
      if (file.modifiedAt != null) '修改日期：${formatDateTime(file.modifiedAt)}',
    ].join('\n');

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 800),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? DesktopTokens.selectedBorder.withValues(alpha: 0.7)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: const Color(0xFFEDEBE6),
                        child: _ThumbnailOrIcon(
                          file: file,
                          getThumbnail: widget.getThumbnail,
                          watchThumbnail: widget.watchThumbnail,
                          iconSize: 40,
                        ),
                      ),
                      if (file.isVideo)
                        const Positioned(
                          right: 6,
                          bottom: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0x99000000),
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(3),
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      if (selected)
                        Positioned(
                          left: 6,
                          top: 6,
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: const BoxDecoration(
                              color: DesktopTokens.selectedBorder,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: DesktopFileGridTile.nameAreaHeight - 12,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: DesktopTokens.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 列表视图各列宽度。名称列自适应。
class DesktopListColumns {
  static const double thumb = 40;
  static const double modified = 160;
  static const double type = 120;
  static const double size = 100;
  static const double rowHeight = 40;
}

class DesktopFileListHeader extends StatelessWidget {
  const DesktopFileListHeader({
    super.key,
    required this.sortBy,
    required this.sortOrder,
    required this.onSort,
  });

  final String sortBy;
  final String sortOrder;
  final void Function(String sortBy, String sortOrder) onSort;

  @override
  Widget build(BuildContext context) {
    Widget headerCell(
      String label, {
      String? key,
      double? width,
      bool right = false,
    }) {
      final active = key != null && key == sortBy;
      final content = Row(
        mainAxisAlignment: right
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: active
                  ? DesktopTokens.textPrimary
                  : DesktopTokens.textSecondary,
            ),
          ),
          if (active) ...[
            const SizedBox(width: 2),
            Icon(
              sortOrder == 'asc'
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              size: 14,
              color: DesktopTokens.textSecondary,
            ),
          ],
        ],
      );
      final cell = key == null
          ? content
          : InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () =>
                  onSort(key, active && sortOrder == 'desc' ? 'asc' : 'desc'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: content,
              ),
            );
      if (width == null) {
        return Expanded(child: cell);
      }
      return SizedBox(width: width, child: cell);
    }

    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DesktopTokens.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: DesktopListColumns.thumb),
          headerCell('名称'),
          headerCell(
            '修改日期',
            key: 'modified',
            width: DesktopListColumns.modified,
          ),
          headerCell('类型', width: DesktopListColumns.type),
          headerCell(
            '大小',
            key: 'size',
            width: DesktopListColumns.size,
            right: true,
          ),
        ],
      ),
    );
  }
}

class DesktopFileListRow extends StatefulWidget {
  const DesktopFileListRow({
    super.key,
    required this.file,
    required this.selected,
    required this.getThumbnail,
    required this.watchThumbnail,
  });

  final FileEntryEntity file;
  final bool selected;
  final Uint8List? Function(String filePath) getThumbnail;
  final Stream<void> Function(String filePath) watchThumbnail;

  @override
  State<DesktopFileListRow> createState() => _DesktopFileListRowState();
}

class _DesktopFileListRowState extends State<DesktopFileListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    const secondary = TextStyle(
      fontSize: 12.5,
      color: DesktopTokens.textSecondary,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        height: DesktopListColumns.rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: widget.selected
              ? DesktopTokens.selected
              : _hovered
              ? DesktopTokens.hover
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            SizedBox(
              width: DesktopListColumns.thumb,
              child: Align(
                alignment: Alignment.centerLeft,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: _ThumbnailOrIcon(
                      file: file,
                      getThumbnail: widget.getThumbnail,
                      watchThumbnail: widget.watchThumbnail,
                      iconSize: 20,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  color: DesktopTokens.textPrimary,
                ),
              ),
            ),
            SizedBox(
              width: DesktopListColumns.modified,
              child: Text(formatDateTime(file.modifiedAt), style: secondary),
            ),
            SizedBox(
              width: DesktopListColumns.type,
              child: Text(
                fileTypeLabel(file),
                style: secondary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: DesktopListColumns.size,
              child: Text(
                file.isFile ? file.formattedSize : '',
                style: secondary,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DesktopSegment<T> {
  const DesktopSegment({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// 紧凑分段切换按钮（类似 Windows 11 资源管理器的视图切换）。
class DesktopSegmented<T> extends StatelessWidget {
  const DesktopSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<DesktopSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFEAE8E3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // 让选中的白色胶囊撑满整个高度（只留 3px 内边距），而不是只包住文字
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final segment in segments)
            _SegmentButton(
              label: segment.label,
              icon: segment.icon,
              selected: segment.value == selected,
              primary: primary,
              onTap: onChanged == null ? null : () => onChanged!(segment.value),
            ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final Color primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? primary : DesktopTokens.textSecondary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        boxShadow: selected
            ? const [
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
