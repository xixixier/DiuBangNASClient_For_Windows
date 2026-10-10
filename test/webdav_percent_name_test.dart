import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasclient/core/path/nas_path.dart';
import 'package:nasclient/core/protocol/webdav_file_protocol_client.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.body);
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      207,
      headers: {
        Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('原机目录：文件名带未编码的 % 不应导致列目录失败', () async {
    const xml = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
<D:response><D:href>/dav/library/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
<D:response><D:href>/dav/library/100%off.jpg</D:href><D:propstat><D:prop><D:displayname>100%off.jpg</D:displayname><D:getcontentlength>12</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
<D:response><D:href>/dav/library/%E7%85%A7%E7%89%87%25.png</D:href><D:propstat><D:prop><D:displayname>照片%.png</D:displayname><D:resourcetype/></D:prop></D:propstat></D:response>
<D:response><D:href>/dav/library/a%20%26%20b.jpg</D:href><D:propstat><D:prop><D:displayname>a &amp; b.jpg</D:displayname><D:resourcetype/></D:prop></D:propstat></D:response>
<D:response><D:href>/dav/library/x%zz.jpg</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
</D:multistatus>''';
    final dio = Dio()..httpClientAdapter = _FakeAdapter(xml);
    final client = WebdavFileProtocolClient(
      baseUrl: 'https://192.168.1.10:8080',
      authHeader: 'Basic ${base64Encode(utf8.encode('a:b'))}',
      dio: dio,
    );
    final entries = await client.listDirectory(NasPath.root('library'));
    expect(entries.map((e) => e.name).toList(), [
      '100%off.jpg',
      '照片%.png',
      'a & b.jpg',
      'x%zz.jpg',
    ]);
    expect(entries.map((e) => e.path).toList(), [
      '/100%off.jpg',
      '/照片%.png',
      '/a & b.jpg',
      '/x%zz.jpg',
    ]);
  });
}
