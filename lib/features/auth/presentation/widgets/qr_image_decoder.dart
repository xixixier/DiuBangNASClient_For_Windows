/// 文件输入：二维码图片字节（截图 / 照片）
/// 文件职责：在没有摄像头扫码能力的平台（Windows）上，用纯 Dart 的 zxing2
///   从图片中识别服务端“连接二维码”
/// 文件对外接口：decodeQrTextFromImageBytes
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// 返回二维码文本；识别失败返回 null。在后台 isolate 中执行，避免卡住 UI。
Future<String?> decodeQrTextFromImageBytes(Uint8List bytes) {
  return compute(_decodeQrTextSync, bytes);
}

String? _decodeQrTextSync(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return null;
  }

  // 依次尝试：原图 → 缩放到较小尺寸（大截图上 zxing 更容易定位）
  final candidates = <img.Image>[decoded];
  final longestSide = decoded.width > decoded.height
      ? decoded.width
      : decoded.height;
  if (longestSide > 1600) {
    candidates.add(
      decoded.width >= decoded.height
          ? img.copyResize(decoded, width: 1200)
          : img.copyResize(decoded, height: 1200),
    );
  }

  for (final image in candidates) {
    final text = _tryDecode(image);
    if (text != null && text.trim().isNotEmpty) {
      return text.trim();
    }
  }
  return null;
}

String? _tryDecode(img.Image image) {
  final pixels = image
      .convert(numChannels: 4)
      .getBytes(order: img.ChannelOrder.abgr)
      .buffer
      .asInt32List();
  final source = RGBLuminanceSource(image.width, image.height, pixels);
  final hints = DecodeHints()..put(DecodeHintType.tryHarder);
  final binarizers = <Binarizer Function()>[
    () => HybridBinarizer(source),
    () => GlobalHistogramBinarizer(source),
  ];
  for (final createBinarizer in binarizers) {
    try {
      final result = QRCodeReader().decode(
        BinaryBitmap(createBinarizer()),
        hints: hints,
      );
      return result.text;
    } catch (_) {
      // 换下一种二值化方式
    }
  }
  return null;
}
