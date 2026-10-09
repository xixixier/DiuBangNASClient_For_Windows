/// 文件输入：摄像头扫码（Android）/ 手动粘贴或二维码图片（Windows）
/// 文件职责：获取服务端“连接二维码”中的配对令牌（NASPAIR3|...）
/// 文件对外接口：QrScannerPage
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:nasclient/core/platform/app_platform.dart';
import 'package:nasclient/features/auth/presentation/widgets/qr_crypto.dart';
import 'package:nasclient/features/auth/presentation/widgets/qr_image_decoder.dart';

class QrScannerPage extends StatelessWidget {
  const QrScannerPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (AppPlatform.supportsCameraQrScan) {
      return const _CameraQrScannerPage();
    }
    // Windows 等桌面平台：绝不调用 mobile_scanner
    return const _ManualPairingInputPage();
  }
}

class _CameraQrScannerPage extends StatefulWidget {
  const _CameraQrScannerPage();

  @override
  State<_CameraQrScannerPage> createState() => _CameraQrScannerPageState();
}

class _CameraQrScannerPageState extends State<_CameraQrScannerPage> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描连接二维码')),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (BarcodeCapture capture) {
              if (_handled) return;
              final barcodes = capture.barcodes;
              if (barcodes.isEmpty) return;
              final raw = (barcodes.first.rawValue ?? '').trim();
              if (!isSupportedQrToken(raw)) return;
              _handled = true;
              Navigator.of(context).pop(raw);
            },
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '请扫描服务端“连接二维码”完成设备注册与 HTTPS 配对。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面端配对：粘贴配对令牌，或选择服务端二维码的截图/图片自动识别。
class _ManualPairingInputPage extends StatefulWidget {
  const _ManualPairingInputPage();

  @override
  State<_ManualPairingInputPage> createState() =>
      _ManualPairingInputPageState();
}

class _ManualPairingInputPageState extends State<_ManualPairingInputPage> {
  final TextEditingController _controller = TextEditingController();
  String? _errorText;
  bool _isDecoding = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 允许用户粘贴整段文本（例如带前后空白、换行或 URL 包裹），从中提取令牌。
  String? _extractToken(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (isSupportedQrToken(trimmed)) {
      return trimmed.replaceAll(RegExp(r'\s+'), '');
    }
    final decoded = Uri.decodeFull(trimmed);
    final index = decoded.indexOf('NASPAIR3|');
    if (index < 0) return null;
    final candidate = decoded
        .substring(index)
        .split(RegExp(r'[\s&#"]'))
        .first
        .trim();
    return isSupportedQrToken(candidate) ? candidate : null;
  }

  void _submit() {
    final token = _extractToken(_controller.text);
    if (token == null) {
      setState(() => _errorText = '未识别到有效的配对令牌（应以 NASPAIR3| 开头）');
      return;
    }
    Navigator.of(context).pop(token);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (!mounted) return;
    setState(() {
      _controller.text = text.trim();
      _errorText = null;
    });
  }

  Future<void> _pickQrImage() async {
    const typeGroup = XTypeGroup(
      label: '图片',
      extensions: <String>['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'],
    );
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[typeGroup],
      confirmButtonText: '识别二维码',
    );
    if (file == null || !mounted) return;
    setState(() {
      _isDecoding = true;
      _errorText = null;
    });
    try {
      final bytes = await file.readAsBytes();
      final text = await decodeQrTextFromImageBytes(bytes);
      if (!mounted) return;
      final token = text == null ? null : _extractToken(text);
      if (token == null) {
        setState(() {
          _errorText = text == null
              ? '未能从图片中识别出二维码，请确认截图清晰完整'
              : '图片中的二维码不是服务端连接二维码';
        });
        return;
      }
      Navigator.of(context).pop(token);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorText = '识别失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isDecoding = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('连接二维码配对')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  '电脑端无法使用摄像头扫码，可任选一种方式完成配对：',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '1. 在服务端打开“连接二维码”，用系统截图（Win + Shift + S）保存为图片后，点击下方“选择二维码图片”。\n'
                  '2. 或者将二维码中的配对令牌（以 NASPAIR3| 开头）粘贴到输入框中。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF6D6C6A),
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _isDecoding ? null : _pickQrImage,
                  icon: _isDecoding
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.image_search_rounded),
                  label: Text(_isDecoding ? '正在识别…' : '选择二维码图片'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  minLines: 3,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: '配对令牌',
                    hintText: 'NASPAIR3|...',
                    errorText: _errorText,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    if (_errorText != null) {
                      setState(() => _errorText = null);
                    }
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pasteFromClipboard,
                      icon: const Icon(Icons.content_paste_rounded),
                      label: const Text('从剪贴板粘贴'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _submit,
                      child: const Text('确认配对'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
