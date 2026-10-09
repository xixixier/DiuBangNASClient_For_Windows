import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail_plugin/video_thumbnail_plugin.dart';

import '../../../../core/platform/app_platform.dart';
import '../../domain/relay_media_kind.dart';
import '../../../../core/storage/app_directories.dart';

class RelayThumbnailGenerator {
  const RelayThumbnailGenerator();

  static const int thumbnailWidth = 320;
  static const int thumbnailQuality = 70;

  Future<String?> generate({
    required String localPath,
    required String transferId,
    required String? mimeType,
  }) async {
    final kind = relayMediaKindFromMime(mimeType);
    if (kind == RelayMediaKind.other) {
      return null;
    }

    final cacheDir = await AppDirectories.appData();
    final thumbDir = Directory(p.join(cacheDir.path, 'relay_thumbnails'));
    if (!await thumbDir.exists()) {
      await thumbDir.create(recursive: true);
    }
    final outputPath = p.join(
      thumbDir.path,
      '${transferId}_thumb${kind == RelayMediaKind.image ? '.png' : '.jpg'}',
    );

    if (kind == RelayMediaKind.image) {
      return _generateImageThumbnail(localPath, outputPath);
    } else {
      return _generateVideoThumbnail(localPath, outputPath, transferId);
    }
  }

  Future<String?> _generateImageThumbnail(
    String sourcePath,
    String outputPath,
  ) async {
    try {
      final bytes = await File(sourcePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: thumbnailWidth,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;

      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      image.dispose();

      if (byteData == null) {
        return null;
      }

      final pngBytes = Uint8List.view(
        byteData.buffer,
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      await File(outputPath).writeAsBytes(pngBytes);
      return outputPath;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _generateVideoThumbnail(
    String sourcePath,
    String outputPath,
    String transferId,
  ) async {
    if (!AppPlatform.isAndroid && !AppPlatform.isIOS) {
      // Windows：video_thumbnail_plugin 无桌面实现，改用 media_kit 截帧；
      // 失败时返回 null，界面会显示通用视频图标。
      return _generateVideoThumbnailWithMediaKit(
        sourcePath,
        outputPath,
        transferId,
      );
    }
    try {
      final status = await VideoThumbnailPlugin.generateImageThumbnail(
        videoPath: sourcePath,
        thumbnailPath: outputPath,
        width: thumbnailWidth,
        height: thumbnailWidth,
        quality: thumbnailQuality,
        format: Format.jpg,
      );
      if (kDebugMode) {
        debugPrint(
          '[RelayThumb] VID-GEN transfer=$transferId ok=$status '
          'src=${sourcePath.length > 40 ? '...${sourcePath.substring(sourcePath.length - 40)}' : sourcePath} '
          'out=$outputPath',
        );
      }
      if (status) {
        return outputPath;
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[RelayThumb] VID-GEN-ERR transfer=$transferId err=$e');
      }
      return null;
    }
  }

  Future<String?> _generateVideoThumbnailWithMediaKit(
    String sourcePath,
    String outputPath,
    String transferId,
  ) async {
    Player? player;
    try {
      player = Player(
        configuration: const PlayerConfiguration(muted: true, osc: false),
      );
      // 挂载 VideoController 以确保 mpv 有视频输出可供截图（不需要显示在界面上）。
      final controller = VideoController(
        player,
        configuration: const VideoControllerConfiguration(
          width: thumbnailWidth * 2,
          height: thumbnailWidth * 2,
        ),
      );
      await player.open(Media(sourcePath), play: false);
      await controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 6),
      );
      final duration = player.state.duration;
      if (duration > const Duration(seconds: 3)) {
        await player.seek(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      final jpegBytes = await player
          .screenshot(format: 'image/jpeg')
          .timeout(const Duration(seconds: 6));
      if (jpegBytes == null || jpegBytes.isEmpty) {
        return null;
      }
      final resized = await compute(_resizeJpeg, jpegBytes);
      await File(outputPath).writeAsBytes(resized ?? jpegBytes);
      return outputPath;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[RelayThumb] MK-VID-GEN-ERR transfer=$transferId err=$e');
      }
      return null;
    } finally {
      await player?.dispose();
    }
  }

  static Uint8List? _resizeJpeg(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }
    final resized = decoded.width > thumbnailWidth
        ? img.copyResize(decoded, width: thumbnailWidth)
        : decoded;
    return img.encodeJpg(resized, quality: thumbnailQuality);
  }

  Future<void> deleteTempFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
