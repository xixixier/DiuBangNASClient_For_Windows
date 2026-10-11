import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasclient/core/path/nas_path.dart';
import 'package:nasclient/core/protocol/webdav_file_protocol_client.dart';
import 'package:nasclient/features/files/data/repositories/file_repository_impl.dart';
import 'package:nasclient/features/files/domain/entities/file_entry_entity.dart';
import 'package:nasclient/features/files/domain/entities/file_type.dart';

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.body, {this.status = 207});
  final String body;
  final int status;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

WebdavFileProtocolClient _client(Dio dio) => WebdavFileProtocolClient(
  baseUrl: 'https://192.168.1.10:8080',
  authHeader: 'Basic ${base64Encode(utf8.encode('a:b'))}',
  dio: dio,
);

void main() {
  test('子文件夹列表：编码过的自身条目会被跳过，子文件夹被识别为目录', () async {
    const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/dav/fs/%E6%97%85%E8%A1%8C/</D:href><D:propstat><D:prop><D:displayname>旅行</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
  <D:response><D:href>/dav/fs/旅行/杭州/</D:href><D:propstat><D:prop><D:displayname>杭州</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
  <D:response><D:href>/dav/fs/旅行/a.jpg</D:href><D:propstat><D:prop><D:displayname>a.jpg</D:displayname><D:resourcetype/><D:getcontentlength>5</D:getcontentlength></D:prop></D:propstat></D:response>
</D:multistatus>''';
    final dio = Dio()..httpClientAdapter = _RecordingAdapter(xml);
    final entries = await _client(
      dio,
    ).listDirectory(const NasPath(rootId: 'fs', path: '/旅行'));
    expect(entries.map((e) => '${e.path}:${e.isDirectory}').toList(), [
      '/旅行/杭州:true',
      '/旅行/a.jpg:false',
    ]);
  });

  test('MOVE 请求带上编码后的 Destination 和 Overwrite: F', () async {
    final adapter = _RecordingAdapter('', status: 201);
    final dio = Dio()..httpClientAdapter = adapter;
    await _client(dio).move(
      const NasPath(rootId: 'fs', path: '/a.jpg'),
      const NasPath(rootId: 'fs', path: '/相册/a.jpg'),
    );
    final request = adapter.requests.single;
    expect(request.method, 'MOVE');
    expect(request.uri.path, '/dav/fs/a.jpg');
    expect(
      request.headers['Destination'],
      'https://192.168.1.10:8080/dav/fs/%E7%9B%B8%E5%86%8C/a.jpg',
    );
    expect(request.headers['Overwrite'], 'F');
  });

  test('文件夹视图排序：文件夹在前按名称，文件按修改时间倒序', () {
    FileEntryEntity e(String name, {bool dir = false, int day = 1}) =>
        FileEntryEntity(
          name: name,
          path: '/$name',
          type: dir ? FileType.directory : FileType.file,
          size: 1,
          modifiedAt: DateTime(2026, 1, day),
        );
    final sorted = FileRepositoryImpl.sortFolderEntries(
      [
        e('b.jpg', day: 1),
        e('Zoo', dir: true),
        e('a.jpg', day: 3),
        e('apple', dir: true),
      ],
      sortBy: 'modified',
      sortOrder: 'desc',
    );
    expect(sorted.map((x) => x.name).toList(), [
      'apple',
      'Zoo',
      'a.jpg',
      'b.jpg',
    ]);
  });
}
