/// 文件输入：文件类型、文件数据
/// 文件职责：将媒体文件保存到系统公共目录
///   - Android：通过 MethodChannel 写入 MediaStore（相册 / Download）
///   - Windows：写入 用户“图片\铥棒文件”（图片/视频）或 “下载\铥棒文件”（其他）
/// 文件对外接口：MediaStorageService
/// 文件包含：MediaStorageService
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../platform/app_platform.dart';
import 'windows_known_folders.dart';

enum MediaFileType { image, video, document }

class MediaStorageService {
  static const _channel = MethodChannel('com.nasclient/media_storage');

  static const int memoryThresholdBytes = 100 * 1024 * 1024;

  Future<String?> saveToPublicStorage({
    required String fileName,
    required Uint8List data,
    required MediaFileType fileType,
  }) async {
    if (AppPlatform.isWindows) {
      final target = await _resolveWindowsTargetFile(fileName, fileType);
      await target.writeAsBytes(data, flush: true);
      return target.path;
    }
    try {
      final fileTypeString = switch (fileType) {
        MediaFileType.image => 'image',
        MediaFileType.video => 'video',
        MediaFileType.document => 'document',
      };

      final result = await _channel.invokeMethod<String>(
        'saveToPublicStorage',
        {'fileName': fileName, 'data': data, 'fileType': fileTypeString},
      );

      return result;
    } on PlatformException catch (e) {
      throw Exception('Failed to save file to public storage: ${e.message}');
    }
  }

  Future<String?> saveFileToPublicStorage({
    required String fileName,
    required String filePath,
    required MediaFileType fileType,
  }) async {
    if (AppPlatform.isWindows) {
      final source = File(filePath);
      if (!await source.exists()) {
        throw Exception('Failed to save file to public storage: $filePath not found');
      }
      final target = await _resolveWindowsTargetFile(fileName, fileType);
      if (p.equals(p.normalize(source.absolute.path), p.normalize(target.path))) {
        return target.path;
      }
      await source.copy(target.path);
      return target.path;
    }
    try {
      final fileTypeString = switch (fileType) {
        MediaFileType.image => 'image',
        MediaFileType.video => 'video',
        MediaFileType.document => 'document',
      };

      final result = await _channel.invokeMethod<String>(
        'saveFileToPublicStorage',
        {
          'fileName': fileName,
          'filePath': filePath,
          'fileType': fileTypeString,
        },
      );

      return result;
    } on PlatformException catch (e) {
      throw Exception('Failed to save file to public storage: ${e.message}');
    }
  }

  MediaFileType getFileTypeFromExtension(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();

    const imageExtensions = [
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
      'heic',
      'heif',
      'raw',
      'tiff',
    ];
    const videoExtensions = [
      'mp4',
      'mkv',
      'avi',
      'mov',
      'wmv',
      'webm',
      '3gp',
      'flv',
      'm4v',
    ];

    if (imageExtensions.contains(extension)) {
      return MediaFileType.image;
    } else if (videoExtensions.contains(extension)) {
      return MediaFileType.video;
    } else {
      return MediaFileType.document;
    }
  }

  bool shouldUseMemory(int fileSizeBytes) {
    return fileSizeBytes <= memoryThresholdBytes;
  }

  Future<Uint8List?> readContentUriBytes(String uri) async {
    if (!AppPlatform.isAndroid) {
      // Windows 上“公共存储 URI”就是普通文件路径。
      try {
        final file = File(_localPathFromUri(uri));
        if (!await file.exists()) return null;
        return await file.readAsBytes();
      } catch (_) {
        return null;
      }
    }
    try {
      final result = await _channel.invokeMethod<Uint8List>(
        'readContentUri',
        {'uri': uri},
      );
      return result;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> deleteContentUri(String uri) async {
    if (!AppPlatform.isAndroid) {
      try {
        final file = File(_localPathFromUri(uri));
        if (!await file.exists()) return false;
        await file.delete();
        return true;
      } catch (_) {
        return false;
      }
    }
    try {
      final result = await _channel.invokeMethod<int>(
        'deleteContentUri',
        {'uri': uri},
      );
      return (result ?? 0) > 0;
    } on PlatformException {
      return false;
    }
  }

  static String _localPathFromUri(String uri) {
    final trimmed = uri.trim();
    if (trimmed.toLowerCase().startsWith('file:')) {
      try {
        return Uri.parse(trimmed).toFilePath(windows: Platform.isWindows);
      } catch (_) {
        return trimmed;
      }
    }
    return trimmed;
  }

  /// Windows：图片/视频保存到 “图片\铥棒文件”，其他文件保存到 “下载\铥棒文件”。
  /// 同名文件自动追加 (1)、(2) 后缀，避免覆盖。
  Future<File> _resolveWindowsTargetFile(
    String fileName,
    MediaFileType fileType,
  ) async {
    final baseDir = switch (fileType) {
      MediaFileType.image || MediaFileType.video =>
        await WindowsKnownFolders.appPicturesDirectory(),
      MediaFileType.document => await WindowsKnownFolders.appDownloadsDirectory(),
    };
    final safeName = WindowsKnownFolders.sanitizeFileName(p.basename(fileName));
    return File(await WindowsKnownFolders.uniquePath(baseDir.path, safeName));
  }
}
