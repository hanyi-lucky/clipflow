import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// 自建服务器 API 封装
class CloudBaseService {
  // 服务器地址：Cloudflare Tunnel 标准 443（无需备案）。
  // 旧直连地址保留作回退：http://121.196.222.122:3000/api
  static const _baseUrl = 'https://api.yihanlife.ccwu.cc/api';

  String? _token;
  String? _openId;
  String? _userId; // 保存用于自动重新登录
  final http.Client _streamClient = http.Client();

  String? get openId => _openId;
  bool get isLoggedIn => _token != null;

  /// Clear all authentication state
  void clearToken() {
    _token = null;
    _openId = null;
    _userId = null;
  }

  /// 登录/注册（userId 从密码派生，相同密码 = 相同账户 = 共享数据）
  Future<void> signInAnonymously({String? userId}) async {
    userId ??= DateTime.now().millisecondsSinceEpoch.toString();
    _userId = userId; // 保存用于自动重新登录
    final response = await http.post(
      Uri.parse('$_baseUrl/auth'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'userId': userId}),
    );

    if (response.statusCode != 200) {
      throw Exception('Auth failed: ${response.body}');
    }

    final result = jsonDecode(response.body);
    if (result['code'] == 'SUCCESS') {
      _token = result['data']['token'];
      _openId = userId;
    } else {
      throw Exception('Auth failed: ${result['message']}');
    }
  }

  /// 发送 HTTP 请求（默认 10 秒超时，防止阻塞同步循环）
  Future<http.Response> _sendRequest(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    Future<http.Response> request;
    switch (method) {
      case 'GET':
        request = http.get(uri, headers: headers);
        break;
      case 'POST':
        request = http.post(uri, headers: headers, body: body);
        break;
      case 'PATCH':
        request = http.patch(uri, headers: headers, body: body);
        break;
      case 'DELETE':
        request = http.delete(uri, headers: headers);
        break;
      default:
        throw Exception('Unsupported method: $method');
    }
    return request.timeout(timeout);
  }

  /// 调用 API（token 失效时自动重新登录并重试）
  Future<Map<String, dynamic>> _callApi(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final headers = {
      'Content-Type': 'application/json',
      if (_token != null) 'Authorization': 'Bearer $_token',
    };

    var response = await _sendRequest(
      method,
      uri,
      headers: headers,
      body: body != null ? jsonEncode(body) : null,
      timeout: timeout,
    );

    // token 失效 → 自动重新登录并重试一次
    if (response.statusCode == 401 && _userId != null) {
      await signInAnonymously(userId: _userId);
      headers['Authorization'] = 'Bearer $_token';
      response = await _sendRequest(
        method,
        uri,
        headers: headers,
        body: body != null ? jsonEncode(body) : null,
        timeout: timeout,
      );
    }

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }

    return jsonDecode(response.body);
  }

  /// 创建文档（兼容旧接口）
  Future<String> addDocument(String collection, Map<String, dynamic> data) async {
    final result = await _callApi('POST', '/clipboard', body: data);
    if (result['code'] != 'SUCCESS') {
      throw Exception('addDocument failed: ${result['message']}');
    }
    return result['id'] as String;
  }

  /// 设置文档（兼容旧接口）
  Future<void> setDocument(String collection, String docId, Map<String, dynamic> data) async {
    if (collection == 'clipboard' && docId == 'current') {
      final result = await _callApi('POST', '/clipboard', body: data);
      if (result['code'] != 'SUCCESS') {
        throw Exception('setDocument failed: ${result['message']}');
      }
    } else if (collection == 'clipboard' && docId == 'salt') {
      final result = await _callApi('POST', '/salt', body: data);
      if (result['code'] != 'SUCCESS') {
        throw Exception('setDocument failed: ${result['message']}');
      }
    } else if (collection == 'devices') {
      final result = await _callApi('POST', '/device', body: {'id': docId, ...data});
      if (result['code'] != 'SUCCESS') {
        throw Exception('setDocument failed: ${result['message']}');
      }
    } else if (collection == 'history') {
      final result = await _callApi('POST', '/clipboard', body: data);
      if (result['code'] != 'SUCCESS') {
        throw Exception('setDocument failed: ${result['message']}');
      }
    }
  }

  /// 获取文档（兼容旧接口）
  Future<Map<String, dynamic>?> getDocument(String collection, String docId) async {
    if (collection == 'clipboard' && docId == 'current') {
      final result = await _callApi('GET', '/clipboard');
      if (result['code'] == 'NOT_FOUND') return null;
      if (result['code'] != 'SUCCESS') return null;
      return result['data'] as Map<String, dynamic>?;
    } else if (collection == 'clipboard' && docId == 'salt') {
      final result = await _callApi('GET', '/salt');
      if (result['code'] == 'NOT_FOUND') return null;
      if (result['code'] != 'SUCCESS') return null;
      return result['data'] as Map<String, dynamic>?;
    }
    return null;
  }

  /// 获取剪切板内容（含 deletedIds，用于同步删除）
  Future<Map<String, dynamic>?> getClipboardWithDeletedIds() async {
    final result = await _callApi('GET', '/clipboard');
    if (result['code'] == 'NOT_FOUND') return null;
    if (result['code'] != 'SUCCESS') return null;
    final data = result['data'] as Map<String, dynamic>?;
    if (data == null) return null;
    final deletedIds = (result['deletedIds'] as List?)?.cast<String>() ?? [];
    final restoredEntries = (result['restoredEntries'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return {...data, '_deletedIds': deletedIds, '_restoredEntries': restoredEntries};
  }

  /// 流式上传文件密文（raw octet-stream）。401 时用 body factory 重放一次。
  Future<http.StreamedResponse> uploadFileStream(
    String filePath, {
    required Map<String, String> headers,
    Duration timeout = const Duration(seconds: 300),
  }) async {
    final uri = Uri.parse('$_baseUrl/file');

    Future<http.StreamedResponse> attempt() async {
      final request = http.StreamedRequest('POST', uri);
      headers.forEach((key, value) {
        request.headers[key] = value;
      });
      if (_token != null) {
        request.headers['Authorization'] = 'Bearer $_token';
      }
      final stream = File(filePath).openRead();
      stream.listen(
        request.sink.add,
        onError: (Object error, StackTrace stack) {
          request.sink.addError(error, stack);
        },
        onDone: request.sink.close,
        cancelOnError: true,
      );
      return _streamClient.send(request).timeout(timeout);
    }

    var response = await attempt();
    if (response.statusCode == 401 && _userId != null) {
      await response.stream.drain<void>();
      await signInAnonymously(userId: _userId);
      response = await attempt();
    }
    return response;
  }

  /// 流式下载文件密文，返回 `StreamedResponse`（调用方负责消费 body）。
  Future<http.StreamedResponse> downloadFileStream(
    String path, {
    Duration timeout = const Duration(seconds: 300),
  }) async {
    final uri = Uri.parse('$_baseUrl$path');

    Future<http.StreamedResponse> attempt() async {
      final request = http.Request('GET', uri);
      request.headers['Accept'] = 'application/octet-stream';
      if (_token != null) {
        request.headers['Authorization'] = 'Bearer $_token';
      }
      return _streamClient.send(request).timeout(timeout);
    }

    var response = await attempt();
    if (response.statusCode == 401 && _userId != null) {
      await response.stream.drain<void>();
      await signInAnonymously(userId: _userId);
      response = await attempt();
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw Exception('HTTP ${response.statusCode}: $body');
    }
    return response;
  }

  /// 恢复已删除的历史记录
  Future<void> restoreHistoryEntry(String entryId) async {
    final result = await _callApi('POST', '/history/$entryId/restore');
    if (result['code'] != 'SUCCESS') {
      throw Exception('restoreHistoryEntry failed');
    }
  }

  /// 倾倒垃圾桶：永久删除当前用户所有软删历史条目，返回删除数量。
  Future<int> emptyTrash() async {
    final result = await _callApi('DELETE', '/history/trash');
    if (result['code'] != 'SUCCESS') {
      throw Exception('emptyTrash failed: ${result['message']}');
    }
    return (result['deleted'] as num?)?.toInt() ?? 0;
  }

  /// 获取历史记录完整内容（图片全图密文）
  Future<Map<String, dynamic>?> getHistoryEntryContent(String entryId) async {
    final result = await _callApi('GET', '/history/$entryId/content');
    if (result['code'] != 'SUCCESS') return null;
    return result['data'] as Map<String, dynamic>?;
  }

  /// 查询文档列表（兼容旧接口）
  Future<List<Map<String, dynamic>>> queryDocuments(
    String collection, {
    Map<String, dynamic>? filter,
    String? orderBy,
    bool descending = false,
    int limit = 100,
  }) async {
    if (collection == 'history') {
      // 历史列表可能包含大体积条目，放宽到 20 秒（其他请求保持 10 秒）
      final result = await _callApi(
        'GET',
        '/history?limit=$limit',
        timeout: const Duration(seconds: 20),
      );
      if (result['code'] != 'SUCCESS') return [];
      final records = result['data']['records'] as List? ?? [];
      return records.cast<Map<String, dynamic>>();
    } else if (collection == 'trash') {
      final result = await _callApi(
        'GET',
        '/history/trash',
        timeout: const Duration(seconds: 20),
      );
      if (result['code'] != 'SUCCESS') return [];
      final records = result['data']['records'] as List? ?? [];
      return records.cast<Map<String, dynamic>>();
    } else if (collection == 'devices') {
      final result = await _callApi('GET', '/devices');
      if (result['code'] != 'SUCCESS') return [];
      return (result['data'] as List? ?? []).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// 更新文档（兼容旧接口）
  Future<void> updateDocument(String collection, String docId, Map<String, dynamic> data) async {
    if (collection == 'history') {
      final result = await _callApi('PATCH', '/history/$docId', body: data);
      if (result['code'] != 'SUCCESS') {
        throw Exception('updateDocument failed: ${result['message']}');
      }
    } else if (collection == 'devices') {
      final result = await _callApi('POST', '/device', body: {'id': docId, ...data});
      if (result['code'] != 'SUCCESS') {
        throw Exception('updateDocument failed: ${result['message']}');
      }
    }
  }

  /// 删除文档（兼容旧接口）
  Future<void> deleteDocument(String collection, String docId) async {
    if (collection == 'history') {
      final result = await _callApi('DELETE', '/history/$docId');
      if (result['code'] != 'SUCCESS') {
        throw Exception('deleteDocument failed: ${result['message']}');
      }
    }
  }
}
