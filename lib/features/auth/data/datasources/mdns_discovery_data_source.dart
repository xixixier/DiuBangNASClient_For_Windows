/// 文件输入：NSD 服务（Android MethodChannel）/ Bonsoir（Windows）
/// 文件职责：执行局域网 mDNS 扫描，发现 NAS 服务器
///   - Android：沿用原生 NsdManager（com.nasclient/nsd）
///   - Windows：使用 bonsoir 发现 `_webdavs._tcp` 并解析 TXT / 主机地址
/// 文件对外接口：MdnsDiscoveryDataSource
/// 文件包含：MdnsDiscoveryDataSource
import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/services.dart';

import '../../../../core/node/unified_node.dart';
import '../../../../core/platform/app_platform.dart';

class MdnsDiscoveryDataSource {
  static const _methodChannel = MethodChannel('com.nasclient/nsd');
  static const _eventChannel = EventChannel('com.nasclient/nsd/events');
  StreamSubscription? _eventSubscription;
  StreamController<List<UnifiedNode>>? _controller;
  bool _isRunning = false;

  // Windows (bonsoir)
  final List<BonsoirDiscovery> _bonsoirDiscoveries = <BonsoirDiscovery>[];
  final List<StreamSubscription<BonsoirDiscoveryEvent>> _bonsoirSubscriptions =
      <StreamSubscription<BonsoirDiscoveryEvent>>[];

  static const List<String> serviceTypes = ['_webdavs._tcp.'];

  Stream<List<UnifiedNode>> discoverServers() async* {
    if (AppPlatform.isAndroid) {
      yield* _discoverServersAndroid();
      return;
    }
    yield* _discoverServersBonsoir();
  }

  void stopDiscovery() {
    _isRunning = false;
    _eventSubscription?.cancel();
    _eventSubscription = null;
    if (AppPlatform.isAndroid) {
      _controller?.close();
      _methodChannel.invokeMethod('stopDiscovery');
      return;
    }
    unawaited(_stopBonsoir());
    _controller?.close();
  }

  // ---------------------------------------------------------------------------
  // Android：原生 NsdManager
  // ---------------------------------------------------------------------------

  Stream<List<UnifiedNode>> _discoverServersAndroid() async* {
    if (_isRunning) return;
    _isRunning = true;

    final serversByServiceName = <String, UnifiedNode>{};
    _controller = StreamController<List<UnifiedNode>>.broadcast();

    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          final method = event['method'] as String?;
          if (method == 'onServiceFound') {
            final name = event['name'] as String?;
            final host = event['host'] as String?;
            final port = event['port'] as int?;
            final serviceType = event['serviceType'] as String?;
            final txtRecords = _parseTxtRecords(event['txtRecords']);

            if (name != null && host != null && port != null) {
              final server = _buildServer(
                name: name,
                host: host,
                port: port,
                serviceType: serviceType ?? 'unknown',
                txtRecords: txtRecords,
              );
              serversByServiceName[name] = server;
              _controller?.add(
                List<UnifiedNode>.from(serversByServiceName.values),
              );
            }
          } else if (method == 'onServiceLost') {
            final name = event['name'] as String?;
            if (name != null && serversByServiceName.remove(name) != null) {
              _controller?.add(
                List<UnifiedNode>.from(serversByServiceName.values),
              );
            }
          } else {
            _controller?.add(
              List<UnifiedNode>.from(serversByServiceName.values),
            );
          }
        }
      },
      onError: (error) {
        _controller?.addError(error);
      },
    );

    try {
      await _methodChannel.invokeMethod('startDiscovery', {
        'serviceTypes': serviceTypes,
      });

      yield* _controller!.stream;
    } catch (e) {
      yield List<UnifiedNode>.from(serversByServiceName.values);
    } finally {
      _isRunning = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Windows：bonsoir
  // ---------------------------------------------------------------------------

  Stream<List<UnifiedNode>> _discoverServersBonsoir() async* {
    if (_isRunning) return;
    _isRunning = true;

    final serversByServiceName = <String, UnifiedNode>{};
    final controller = StreamController<List<UnifiedNode>>.broadcast();
    _controller = controller;

    void emit() {
      if (!controller.isClosed) {
        controller.add(List<UnifiedNode>.from(serversByServiceName.values));
      }
    }

    try {
      for (final rawType in serviceTypes) {
        final type = _normalizeServiceType(rawType);
        final discovery = BonsoirDiscovery(type: type, printLogs: false);
        await discovery.initialize();
        _bonsoirDiscoveries.add(discovery);

        final subscription = discovery.eventStream?.listen(
          (event) {
            switch (event) {
              case final BonsoirDiscoveryServiceFoundEvent found:
                // 发现后主动解析，拿到主机名与端口
                unawaited(
                  discovery.serviceResolver
                      .resolveService(found.service)
                      .catchError((Object _) {}),
                );
              case final BonsoirDiscoveryServiceResolvedEvent resolved:
                unawaited(
                  _handleResolvedService(
                    resolved.service,
                    serviceType: rawType,
                    serversByServiceName: serversByServiceName,
                    onChanged: emit,
                  ),
                );
              case final BonsoirDiscoveryServiceUpdatedEvent updated:
                unawaited(
                  _handleResolvedService(
                    updated.service,
                    serviceType: rawType,
                    serversByServiceName: serversByServiceName,
                    onChanged: emit,
                  ),
                );
              case final BonsoirDiscoveryServiceLostEvent lost:
                if (serversByServiceName.remove(lost.service.name) != null) {
                  emit();
                }
              default:
                break;
            }
          },
          onError: (Object error) {
            if (!controller.isClosed) {
              controller.addError(error);
            }
          },
        );
        if (subscription != null) {
          _bonsoirSubscriptions.add(subscription);
        }
        await discovery.start();
      }

      // 先推送一次空列表，便于 UI 退出“扫描中”的初始态
      emit();
      yield* controller.stream;
    } catch (_) {
      yield List<UnifiedNode>.from(serversByServiceName.values);
    } finally {
      _isRunning = false;
    }
  }

  Future<void> _handleResolvedService(
    BonsoirService service, {
    required String serviceType,
    required Map<String, UnifiedNode> serversByServiceName,
    required void Function() onChanged,
  }) async {
    final rawHost = service.host?.trim();
    if (rawHost == null || rawHost.isEmpty || service.port <= 0) {
      return;
    }
    final host = await _resolveHostAddress(rawHost);
    if (!_isRunning) {
      return;
    }
    final server = _buildServer(
      name: service.name,
      host: host,
      port: service.port,
      serviceType: serviceType,
      txtRecords: service.attributes,
    );
    serversByServiceName[service.name] = server;
    onChanged();
  }

  /// Windows 上 bonsoir 返回的是 `xxx.local` 主机名；Android 原生返回 IP。
  /// 为与 Android 行为保持一致（URL / 证书信任主机均使用 IP），这里优先解析为
  /// 局域网 IPv4，失败时保留主机名。
  Future<String> _resolveHostAddress(String rawHost) async {
    var host = rawHost;
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    if (InternetAddress.tryParse(host) != null) {
      return host;
    }
    try {
      final addresses = await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 3));
      if (addresses.isEmpty) {
        return host;
      }
      for (final address in addresses) {
        if (_isPrivateIpv4(address.address)) {
          return address.address;
        }
      }
      return addresses.first.address;
    } catch (_) {
      return host;
    }
  }

  bool _isPrivateIpv4(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]) ?? -1;
    final b = int.tryParse(parts[1]) ?? -1;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  Future<void> _stopBonsoir() async {
    for (final subscription in _bonsoirSubscriptions) {
      await subscription.cancel();
    }
    _bonsoirSubscriptions.clear();
    for (final discovery in _bonsoirDiscoveries) {
      try {
        if (!discovery.isStopped) {
          await discovery.stop().timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
        }
      } catch (_) {
        // ignore
      }
    }
    _bonsoirDiscoveries.clear();
  }

  static String _normalizeServiceType(String type) {
    var normalized = type.trim();
    while (normalized.endsWith('.')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  // ---------------------------------------------------------------------------
  // 公共
  // ---------------------------------------------------------------------------

  UnifiedNode _buildServer({
    required String name,
    required String host,
    required int port,
    required String serviceType,
    required Map<String, String> txtRecords,
  }) {
    return UnifiedNode.discoveredServer(
      name: name,
      host: host,
      port: port,
      serviceType: serviceType,
      serverId: txtRecords['serverId'],
      caSha256: txtRecords['caSha256'],
      scheme: txtRecords['scheme'],
      baseUrl: txtRecords['baseUrl'],
      hostLabel: txtRecords['hostLabel'],
      platform: txtRecords['platform'],
    );
  }

  Map<String, String> _parseTxtRecords(dynamic rawValue) {
    if (rawValue is! Map) {
      return const <String, String>{};
    }
    return rawValue.map(
      (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
    );
  }
}
