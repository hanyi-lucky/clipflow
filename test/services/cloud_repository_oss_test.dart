import 'dart:io';

import 'package:clipflow/repositories/cloud_repository.dart';
import 'package:clipflow/services/cloudbase_service.dart';
import 'package:clipflow/services/oss_direct_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 假 CloudBaseService：只覆写 OSS presign 三方法 + 文件流式 relay 计数，
/// 用于验证 CloudRepository 的「直传/直下优先 + 回退 relay」路由。
class _FakeCloudBaseService extends CloudBaseService {
  Map<String, dynamic>? presignUploadData;
  bool failPresignUpload = false;
  bool failConfirmPresignUpload = false;
  Map<String, dynamic>? presignDownloadData;
  bool failPresignDownload = false;

  int uploadFileStreamCalls = 0;
  int downloadFileStreamCalls = 0;
  String? lastConfirmHistoryId;
  String? lastConfirmFileKey;

  @override
  Future<Map<String, dynamic>> presignUpload({
    required Map<String, String> headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (failPresignUpload) throw Exception('HTTP 503: OSS direct upload not configured');
    return {'code': 'SUCCESS', 'data': presignUploadData ?? const {}};
  }

  @override
  Future<Map<String, dynamic>> confirmPresignUpload({
    required String historyId,
    required String fileKey,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    lastConfirmHistoryId = historyId;
    lastConfirmFileKey = fileKey;
    if (failConfirmPresignUpload) throw Exception('HTTP 400: FILE_SIZE_MISMATCH');
    return {'code': 'SUCCESS', 'id': historyId};
  }

  @override
  Future<Map<String, dynamic>> presignDownload(String entryId) async {
    if (failPresignDownload) throw Exception('HTTP 500: presign download failed');
    return {'code': 'SUCCESS', 'data': presignDownloadData ?? const {}};
  }

  @override
  Future<http.StreamedResponse> uploadFileStream(
    String filePath, {
    required Map<String, String> headers,
    Duration timeout = const Duration(seconds: 300),
  }) async {
    uploadFileStreamCalls++;
    return http.StreamedResponse(Stream.fromIterable(const []), 200);
  }

  @override
  Future<http.StreamedResponse> downloadFileStream(
    String path, {
    Duration timeout = const Duration(seconds: 300),
  }) async {
    downloadFileStreamCalls++;
    return http.StreamedResponse(Stream.fromIterable(const []), 200);
  }
}

/// 假 http.Client：内存字节存储（按 URL），记录 PUT/GET，可注入失败分支。
class _FakeHttpClient extends http.BaseClient {
  final Map<Uri, List<int>> store = {};
  final List<http.BaseRequest> sentRequests = [];
  int putCalls = 0;
  int getCalls = 0;
  bool failPut = false;
  bool failGet = false;
  int putStatus = 200;
  int getStatus = 200;
  List<int>? getBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sentRequests.add(request);
    if (request.method == 'PUT') {
      putCalls++;
      if (failPut) throw Exception('Connection refused');
      final bytes = await request.finalize().fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      store[request.url] = bytes;
      return http.StreamedResponse(Stream.fromIterable(const []), putStatus);
    }
    if (request.method == 'GET') {
      getCalls++;
      if (failGet) throw Exception('Connection refused');
      final bytes = getBody ?? store[request.url] ?? const <int>[];
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable([bytes]),
        getStatus,
        contentLength: bytes.length,
      );
    }
    throw UnsupportedError('unsupported method ${request.method}');
  }
}

void main() {
  late _FakeCloudBaseService cloud;
  late _FakeHttpClient httpClient;
  late CloudRepository repository;
  late File tempFile;
  final cipherBytes = List<int>.generate(64 * 1024, (i) => i % 251);
  const historyId = 'entry-oss-1';
  const fileKey = 'oss:11111111-2222-4333-8444-555555555555';
  const uploadUrl = 'http://fake-oss/clipflow/user_1/11111111-2222-4333-8444-555555555555';
  const downloadUrl = 'http://fake-oss/clipflow/user_1/11111111-2222-4333-8444-555555555555';

  setUp(() async {
    cloud = _FakeCloudBaseService();
    httpClient = _FakeHttpClient();
    repository = CloudRepository(
      cloud,
      ossDirectClient: OssDirectClient(client: httpClient),
    );
    tempFile = File(
      '${Directory.systemTemp.path}/cloud_repository_oss_test_${DateTime.now().microsecondsSinceEpoch}.bin',
    );
    await tempFile.writeAsBytes(cipherBytes, flush: true);
  });

  tearDown(() async {
    if (await tempFile.exists()) await tempFile.delete();
  });

  Future<void> upload() {
    return repository.uploadFile(
      encryptedPath: tempFile.path,
      historyId: historyId,
      plaintextHash: 'HASH_1',
      fileName: 'a.bin',
      fileSize: 4096,
      mimeType: 'application/octet-stream',
      marker: 'M',
      sourceDevice: 'dev-1',
      sourceDeviceName: 'Mac',
      sourcePlatform: 'macos',
      timestamp: 1700000000000,
    );
  }

  test('1. 直传成功：PUT 到假 presign URL、流式 body、confirm 被调、relay 未调', () async {
    cloud.presignUploadData = {'uploadUrl': uploadUrl, 'fileKey': fileKey};
    await upload();

    expect(httpClient.putCalls, 1);
    expect(httpClient.sentRequests.single.url.toString(), uploadUrl);
    expect(httpClient.store[Uri.parse(uploadUrl)], cipherBytes);
    expect(cloud.lastConfirmHistoryId, historyId);
    expect(cloud.lastConfirmFileKey, fileKey);
    expect(cloud.uploadFileStreamCalls, 0);
  });

  test('2. presign 503 → 回退 relay', () async {
    cloud.failPresignUpload = true;
    await upload();
    expect(cloud.uploadFileStreamCalls, 1);
    expect(httpClient.putCalls, 0);
  });

  test('3. PUT 失败/超时 → 回退 relay', () async {
    cloud.presignUploadData = {'uploadUrl': uploadUrl, 'fileKey': fileKey};
    httpClient.failPut = true;
    await upload();
    expect(cloud.uploadFileStreamCalls, 1);
    expect(httpClient.putCalls, 1);
  });

  test('4. confirm 400 → 回退 relay', () async {
    cloud.presignUploadData = {'uploadUrl': uploadUrl, 'fileKey': fileKey};
    cloud.failConfirmPresignUpload = true;
    await upload();
    expect(cloud.uploadFileStreamCalls, 1);
    expect(httpClient.putCalls, 1);
    expect(cloud.lastConfirmFileKey, fileKey);
  });

  test('5. 直下成功：presign-download 返回 oss URL → fake GET → contentLength 正确；relay 未调', () async {
    cloud.presignDownloadData = {'storage': 'oss', 'downloadUrl': downloadUrl};
    httpClient.getBody = cipherBytes;

    final response = await repository.downloadFile(historyId);

    expect(response.statusCode, 200);
    expect(response.contentLength, cipherBytes.length);
    final bytes = await response.stream.fold<List<int>>(<int>[], (a, c) => a..addAll(c));
    expect(bytes, cipherBytes);
    expect(httpClient.getCalls, 1);
    expect(cloud.downloadFileStreamCalls, 0);
  });

  test('6. 直下失败 → 回退 relay', () async {
    cloud.presignDownloadData = {'storage': 'oss', 'downloadUrl': downloadUrl};
    httpClient.failGet = true;

    final response = await repository.downloadFile(historyId);
    expect(response.statusCode, 200);
    expect(cloud.downloadFileStreamCalls, 1);
    expect(httpClient.getCalls, 1);
  });

  test('7. storage:disk → 直接 relay，无 GET', () async {
    cloud.presignDownloadData = {'storage': 'disk'};

    final response = await repository.downloadFile(historyId);
    expect(response.statusCode, 200);
    expect(cloud.downloadFileStreamCalls, 1);
    expect(httpClient.getCalls, 0);
  });

  test('8. 假 URL 端到端往返：presign→PUT 与 presign-download 同一 key → 取回同一密文', () async {
    cloud.presignUploadData = {'uploadUrl': uploadUrl, 'fileKey': fileKey};
    await upload();

    cloud.presignDownloadData = {'storage': 'oss', 'downloadUrl': downloadUrl};
    final response = await repository.downloadFile(historyId);
    final bytes = await response.stream.fold<List<int>>(<int>[], (a, c) => a..addAll(c));

    expect(bytes, cipherBytes);
    expect(cloud.lastConfirmHistoryId, historyId);
    expect(cloud.lastConfirmFileKey, fileKey);
    expect(cloud.uploadFileStreamCalls, 0);
    expect(cloud.downloadFileStreamCalls, 0);
  });
}
