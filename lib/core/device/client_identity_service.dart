/// 文件输入：设备信息、安装实例标识、本地缓存
/// 文件职责：生成并维护客户端设备唯一标识
/// 文件对外接口：ClientIdentityService
/// 文件包含：ClientIdentityService
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_id_normalizer.dart';

class ClientDeviceDetails {
  const ClientDeviceDetails({
    required this.name,
    required this.type,
    this.brand,
    this.model,
  });

  final String name;
  final String type;
  final String? brand;
  final String? model;
}

class ClientIdentityService {
  static const _keyDeviceId = 'client_device_id';
  static const MethodChannel _deviceIdentityChannel = MethodChannel(
    'com.nasclient/device_identity',
  );
  final SharedPreferences _prefs;
  final DeviceInfoPlugin _deviceInfo;
  final Future<String?> Function()? _androidIdResolver;
  final bool Function()? _isAndroidPlatform;
  final bool Function()? _isIosPlatform;
  final bool Function()? _isWindowsPlatform;
  String? _cachedId;
  ClientDeviceDetails? _cachedDetails;

  ClientIdentityService({
    required SharedPreferences prefs,
    DeviceInfoPlugin? deviceInfo,
    Future<String?> Function()? androidIdResolver,
    bool Function()? isAndroidPlatform,
    bool Function()? isIosPlatform,
    bool Function()? isWindowsPlatform,
  }) : _prefs = prefs,
       _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
       _androidIdResolver = androidIdResolver,
       _isAndroidPlatform = isAndroidPlatform,
       _isIosPlatform = isIosPlatform,
       _isWindowsPlatform = isWindowsPlatform;

  Future<String> getDeviceId() async {
    if (_cachedId != null) return _cachedId!;

    final deviceId = DeviceIdNormalizer.normalizeRequired(
      await _resolvePreferredDeviceId(),
    );
    if (_prefs.getString(_keyDeviceId) != deviceId) {
      await _prefs.setString(_keyDeviceId, deviceId);
    }
    _cachedId = deviceId;
    return deviceId;
  }

  Future<String> _resolvePreferredDeviceId() async {
    if (_isRunningOnAndroid()) {
      final androidId = await _resolveAndroidId();
      if (androidId != null && androidId.isNotEmpty) {
        await _prefs.setString(_keyDeviceId, androidId);
        return androidId;
      }
      throw StateError(
        'ANDROID_ID is required on Android platform but unavailable',
      );
    }

    if (_isRunningOnIos()) {
      final idfv = await _resolveIdfv();
      if (idfv != null && idfv.isNotEmpty) {
        await _prefs.setString(_keyDeviceId, idfv);
        return idfv;
      }
      throw StateError(
        'IDFV is required on iOS platform but unavailable',
      );
    }

    if (_isRunningOnWindows()) {
      return _resolveWindowsDeviceId();
    }

    throw UnsupportedError(
      'Unsupported platform. Only Android, iOS and Windows are supported.',
    );
  }

  /// Windows：优先沿用已持久化的 ID；否则读取系统 MachineId（device_info_plus），
  /// 最后兜底为随机 UUID 并持久化，保证同一安装实例 ID 稳定。
  Future<String> _resolveWindowsDeviceId() async {
    final stored = DeviceIdNormalizer.normalize(_prefs.getString(_keyDeviceId));
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }

    String? candidate;
    try {
      final windowsInfo = await _deviceInfo.windowsInfo;
      final raw = windowsInfo.deviceId
          .trim()
          .replaceAll('{', '')
          .replaceAll('}', '')
          .toLowerCase();
      if (raw.isNotEmpty) {
        candidate = 'windows-$raw';
      }
    } catch (_) {
      candidate = null;
    }

    candidate ??= 'windows-${_generateUuidV4()}';
    final normalized = DeviceIdNormalizer.normalizeRequired(candidate);
    await _prefs.setString(_keyDeviceId, normalized);
    return normalized;
  }

  static String _generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  bool _isRunningOnWindows() {
    if (_isWindowsPlatform != null) {
      return _isWindowsPlatform();
    }
    return !kIsWeb && Platform.isWindows;
  }

  bool _isRunningOnAndroid() {
    if (_isAndroidPlatform != null) {
      return _isAndroidPlatform();
    }
    return !kIsWeb && Platform.isAndroid;
  }

  bool _isRunningOnIos() {
    if (_isIosPlatform != null) {
      return _isIosPlatform();
    }
    return !kIsWeb && Platform.isIOS;
  }

  Future<String?> _resolveAndroidId() async {
    try {
      final androidId =
          await (_androidIdResolver?.call() ??
              _deviceIdentityChannel.invokeMethod<String>('getAndroidId'));
      final normalized = androidId?.trim().toLowerCase();
      if (normalized == null || normalized.isEmpty) {
        return null;
      }
      return DeviceIdNormalizer.normalize(normalized);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<String?> _resolveIdfv() async {
    try {
      final iosInfo = await _deviceInfo.iosInfo;
      final idfv = iosInfo.identifierForVendor?.trim();
      if (idfv == null || idfv.isEmpty) {
        return null;
      }
      return DeviceIdNormalizer.normalize(idfv);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<String> getDeviceName() async {
    return (await getDeviceDetails()).name;
  }

  Future<String> getDeviceType() async {
    return (await getDeviceDetails()).type;
  }

  Future<String?> getDeviceBrand() async {
    return (await getDeviceDetails()).brand;
  }

  Future<String?> getDeviceModel() async {
    return (await getDeviceDetails()).model;
  }

  Future<ClientDeviceDetails> getDeviceDetails() async {
    final cachedDetails = _cachedDetails;
    if (cachedDetails != null) {
      return cachedDetails;
    }

    final details = await _buildDeviceDetails();
    _cachedDetails = details;
    return details;
  }

  Future<ClientDeviceDetails> _buildDeviceDetails() async {
    final deviceInfo = _deviceInfo;

    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return ClientDeviceDetails(
        name: '${androidInfo.manufacturer} ${androidInfo.model}',
        type: 'android',
        brand: androidInfo.manufacturer,
        model: androidInfo.model,
      );
    }
    if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return ClientDeviceDetails(
        name: iosInfo.utsname.machine,
        type: 'ios',
        brand: 'Apple',
        model: iosInfo.utsname.machine,
      );
    }

    if (Platform.isWindows) {
      try {
        final windowsInfo = await deviceInfo.windowsInfo;
        final computerName = windowsInfo.computerName.trim();
        final productName = windowsInfo.productName.trim();
        return ClientDeviceDetails(
          name: computerName.isNotEmpty ? computerName : 'Windows PC',
          type: 'windows',
          brand: 'Windows',
          model: productName.isNotEmpty ? productName : 'Windows PC',
        );
      } catch (_) {
        final hostName = Platform.localHostname.trim();
        return ClientDeviceDetails(
          name: hostName.isNotEmpty ? hostName : 'Windows PC',
          type: 'windows',
          brand: 'Windows',
          model: 'Windows PC',
        );
      }
    }

    throw UnsupportedError(
      'Unsupported platform. Only Android, iOS and Windows are supported.',
    );
  }
}
