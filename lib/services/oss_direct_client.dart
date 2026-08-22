import 'dart:io';

import 'package:http/http.dart' as http;

/// OSS 直连客户端（Phase 5.3）：直传/直下阿里云 OSS 预签名 URL。
///
/// 与自建服务器中转（[createPinnedHttpClient] 指纹固定）分离——OSS 域名是
/// 阿里云公网标准 TLS，不使用自建服务器证书固定；默认普通 [http.Client]，
/// 构造可注入 fake client 供单测断言（直传/直下/错误分支）。
class OssDirectClient {
  final http.Client client;

  OssDirectClient({http.Client? client}) : client = client ?? http.Client();

  /// 流式直传（PUT 预签名 URL）：`StreamedRequest` + `File.openRead()` 管道，
  /// 绝不整文件进内存（与 `uploadFileStream` 同构）。返回原始响应，调用方负责消费 body。
  Future<http.StreamedResponse> putStream(
    Uri url,
    String filePath, {
    Duration timeout = const Duration(seconds: 300),
  }) async {
    final request = http.StreamedRequest('PUT', url);
    final stream = File(filePath).openRead();
    stream.listen(
      request.sink.add,
      onError: (Object error, StackTrace stack) {
        request.sink.addError(error, stack);
      },
      onDone: request.sink.close,
      cancelOnError: true,
    );
    return client.send(request).timeout(timeout);
  }

  /// 直下（GET 预签名 URL）：返回流式响应，调用方负责消费 body。
  Future<http.StreamedResponse> getStream(
    Uri url, {
    Duration timeout = const Duration(seconds: 300),
  }) async {
    final request = http.Request('GET', url);
    request.headers['Accept'] = 'application/octet-stream';
    return client.send(request).timeout(timeout);
  }
}
