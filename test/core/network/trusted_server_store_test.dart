import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nasclient/core/network/trusted_server_store.dart';
import 'package:nasclient/core/storage/secure_store.dart';

class _MemorySecureStore extends SecureStore {
  final Map<String, String> values = {};

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('重装服务端后同一地址重新配对：使用新证书，旧记录被清理', () async {
    final secure = _MemorySecureStore();
    final store = TrustedServerStore(secureStore: secure);
    await store.trustServer(
      serverId: 'old',
      baseUrl: 'https://192.168.1.4:8080',
      rootCaPem: 'OLD',
      caSha256: 'old-sha',
    );
    await store.trustServer(
      serverId: 'new',
      baseUrl: 'https://192.168.1.4:8080',
      rootCaPem: 'NEW',
      caSha256: 'new-sha',
    );
    expect(store.findByServerUrl('https://192.168.1.4:8080')?.serverId, 'new');
    expect(store.findByServerId('old'), isNull);
  });

  test('已经存了冲突记录的旧数据：按最近配对的记录匹配', () async {
    final secure = _MemorySecureStore();
    Map<String, dynamic> record(String id) => {
      'serverId': id,
      'serverName': '',
      'caSha256': '$id-sha',
      'rootCaPem': id,
      'lastBaseUrl': 'https://192.168.1.4:8080',
      'hosts': ['192.168.1.4'],
    };
    secure.values['trusted_server_records_v1'] = jsonEncode([
      record('old'),
      record('new'),
    ]);
    final store = TrustedServerStore(secureStore: secure);
    await store.initialize();
    expect(store.findByServerUrl('https://192.168.1.4:8080')?.serverId, 'new');
  });

  test('另一台服务端的其他地址保留', () async {
    final store = TrustedServerStore(secureStore: _MemorySecureStore());
    await store.trustServer(
      serverId: 'a',
      baseUrl: 'https://10.0.0.2:8080',
      rootCaPem: 'A',
      caSha256: 'a',
    );
    await store.trustServer(
      serverId: 'a',
      baseUrl: 'https://192.168.1.4:8080',
      rootCaPem: 'A',
      caSha256: 'a',
    );
    await store.trustServer(
      serverId: 'b',
      baseUrl: 'https://192.168.1.4:8080',
      rootCaPem: 'B',
      caSha256: 'b',
    );
    expect(store.findByServerUrl('https://10.0.0.2:8080')?.serverId, 'a');
    expect(store.findByServerUrl('https://192.168.1.4:8080')?.serverId, 'b');
  });
}
