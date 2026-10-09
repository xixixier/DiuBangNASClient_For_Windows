/// 文件输入：本地文件夹路径、文件选择对话框
/// 文件职责：桌面端（Windows）媒体文件工具：
///   - 图片/视频扩展名判定
///   - 多选本地图片/视频（替代 Android 图库选择器 wechat_assets_picker）
///   - 递归扫描文件夹中的图片/视频（替代 photo_manager 整机图库扫描）
/// 文件对外接口：DesktopMediaFiles、DesktopMediaFile、DesktopMediaScanProgress
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

class DesktopMediaFile {
  const DesktopMediaFile({
    required this.path,
    required this.displayName,
    required this.size,
    required this.modifiedAt,
    required this.isVideo,
    required this.rootFolder,
  });

  final String path;
  final String displayName;
  final int size;
  final DateTime modifiedAt;
  final bool isVideo;

  /// 该文件所属的被选中的根文件夹（用于展示来源）。
  final String rootFolder;

  /// 稳定的来源标识：规范化（小写）绝对路径。用于备份指纹 / 去重。
  String get stableId => DesktopMediaFiles.stableIdForPath(path);
}

class DesktopMediaScanProgress {
  const DesktopMediaScanProgress({
    required this.scannedEntries,
    required this.discoveredItems,
    required this.currentFolder,
  });

  final int scannedEntries;
  final int discoveredItems;
  final String currentFolder;
}

class DesktopMediaFiles {
  DesktopMediaFiles._();

  static const Set<String> imageExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.heic',
    '.heif',
    '.tif',
    '.tiff',
    '.dng',
    '.raw',
    '.cr2',
    '.nef',
    '.arw',
  };

  static const Set<String> videoExtensions = <String>{
    '.mp4',
    '.mov',
    '.mkv',
    '.avi',
    '.wmv',
    '.webm',
    '.3gp',
    '.flv',
    '.m4v',
    '.mts',
    '.m2ts',
    '.ts',
  };

  /// Windows 系统 / 隐藏目录，扫描时跳过。
  static const Set<String> _skippedDirectoryNames = <String>{
    r'$recycle.bin',
    'system volume information',
    'thumbs',
    '.thumbnails',
    '.trash',
    'node_modules',
    '.git',
  };

  static bool isImagePath(String path) =>
      imageExtensions.contains(p.extension(path).toLowerCase());

  static bool isVideoPath(String path) =>
      videoExtensions.contains(p.extension(path).toLowerCase());

  static bool isMediaPath(String path) => isImagePath(path) || isVideoPath(path);

  static String stableIdForPath(String path) =>
      p.normalize(File(path).absolute.path).toLowerCase();

  static List<String> _extensionsFor({
    required bool includeImages,
    required bool includeVideos,
  }) {
    return <String>[
      if (includeImages) ...imageExtensions,
      if (includeVideos) ...videoExtensions,
    ].map((ext) => ext.substring(1)).toList(growable: false);
  }

  /// 弹出系统文件对话框多选图片 / 视频，返回绝对路径列表。
  static Future<List<String>> pickMediaFilePaths({
    bool includeImages = true,
    bool includeVideos = true,
  }) async {
    if (!includeImages && !includeVideos) {
      return const <String>[];
    }
    final label = includeImages && includeVideos
        ? '图片和视频'
        : (includeImages ? '图片' : '视频');
    final typeGroup = XTypeGroup(
      label: label,
      extensions: _extensionsFor(
        includeImages: includeImages,
        includeVideos: includeVideos,
      ),
    );
    final files = await openFiles(
      acceptedTypeGroups: <XTypeGroup>[typeGroup],
      confirmButtonText: '选择',
    );
    return files
        .map((file) => file.path)
        .where((path) => path.trim().isNotEmpty)
        .toList(growable: false);
  }

  /// 弹出系统对话框选择一个文件夹。
  static Future<String?> pickDirectory({String? confirmButtonText}) {
    return getDirectoryPath(confirmButtonText: confirmButtonText ?? '选择文件夹');
  }

  /// 读取单个文件的元数据；文件不存在或不可读时返回 null。
  static Future<DesktopMediaFile?> describeFile(
    String path, {
    String? rootFolder,
  }) async {
    try {
      final file = File(path);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        return null;
      }
      return DesktopMediaFile(
        path: file.absolute.path,
        displayName: p.basename(path),
        size: stat.size,
        modifiedAt: stat.modified,
        isVideo: isVideoPath(path),
        rootFolder: rootFolder ?? p.dirname(path),
      );
    } catch (_) {
      return null;
    }
  }

  /// 递归扫描 [folders] 中的图片/视频。跳过隐藏/系统目录与无法访问的目录。
  static Future<List<DesktopMediaFile>> scanFolders(
    List<String> folders, {
    bool includeImages = true,
    bool includeVideos = true,
    bool Function()? shouldCancel,
    void Function(DesktopMediaScanProgress progress)? onProgress,
  }) async {
    final results = <DesktopMediaFile>[];
    final seen = <String>{};
    var scannedEntries = 0;

    for (final folder in folders) {
      if (shouldCancel?.call() == true) break;
      final root = Directory(folder);
      if (!await root.exists()) continue;

      final pending = <Directory>[root];
      while (pending.isNotEmpty) {
        if (shouldCancel?.call() == true) break;
        final dir = pending.removeLast();
        List<FileSystemEntity> entries;
        try {
          entries = await dir.list(followLinks: false).toList();
        } catch (_) {
          continue; // 无权限等
        }
        for (final entity in entries) {
          scannedEntries += 1;
          final name = p.basename(entity.path);
          if (entity is Directory) {
            final lower = name.toLowerCase();
            if (lower.startsWith('.') || _skippedDirectoryNames.contains(lower)) {
              continue;
            }
            pending.add(entity);
            continue;
          }
          if (entity is! File) continue;
          final isImage = isImagePath(entity.path);
          final isVideo = !isImage && isVideoPath(entity.path);
          if ((isImage && !includeImages) ||
              (isVideo && !includeVideos) ||
              (!isImage && !isVideo)) {
            continue;
          }
          if (!seen.add(stableIdForPath(entity.path))) continue;
          final described = await describeFile(entity.path, rootFolder: folder);
          if (described != null && described.size > 0) {
            results.add(described);
          }
        }
        if (onProgress != null) {
          onProgress(
            DesktopMediaScanProgress(
              scannedEntries: scannedEntries,
              discoveredItems: results.length,
              currentFolder: dir.path,
            ),
          );
        }
      }
    }

    results.sort((a, b) => a.path.compareTo(b.path));
    return results;
  }
}
