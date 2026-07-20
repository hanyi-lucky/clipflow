import 'dart:convert';
import 'package:http/http.dart' as http;

/// 自建服务器 API 封装
class CloudBaseService {
  // 服务器地址（部署后替换为实际 IP）
  static const _baseUrl = 'http://121.196.222.122:3000/api';

  String? _token;
  String? _openId;
  String? _userId; // 保存用于自动重新登录

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

  /// 发送 HTTP 请求
  Future<http.Response> _sendRequest(String method, Uri uri, {Map<String, String>? headers, Object? body}) async {
    switch (method) {
      case 'GET':
        return http.get(uri, headers: headers);
      case 'POST':
        return http.post(uri, headers: headers, body: body);
      case 'PATCH':
        return http.patch(uri, headers: headers, body: body);
      case 'DELETE':
        return http.delete(uri, headers: headers);
      default:
        throw Exception('Unsupported method: $method');
    }
  }

  /// 调用 API（token 失效时自动重新登录并重试）
  Future<Map<String, dynamic>> _callApi(String method, String path, {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$_baseUrl$path');
    final headers = {
      'Content-Type': 'application/json',
      if (_token != null) 'Authorization': 'Bearer $_token',
    };

    var response = await _sendRequest(method, uri, headers: headers, body: body != null ? jsonEncode(body) : null);

    // token 失效 → 自动重新登录并重试一次
    if (response.statusCode == 401 && _userId != null) {
      await signInAnonymously(userId: _userId);
      headers['Authorization'] = 'Bearer $_token';
      response = await _sendRequest(method, uri, headers: headers, body: body != null ? jsonEncode(body) : null);
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

  /// 恢复已删除的历史记录
  Future<void> restoreHistoryEntry(String entryId) async {
    final result = await _callApi('POST', '/history/$entryId/restore');
    if (result['code'] != 'SUCCESS') {
      throw Exception('restoreHistoryEntry failed');
    }
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
      final result = await _callApi('GET', '/history?limit=$limit');
      if (result['code'] != 'SUCCESS') return [];
      final records = result['data']['records'] as List? ?? [];
      return records.cast<Map<String, dynamic>>();
    } else if (collection == 'trash') {
      final result = await _callApi('GET', '/history/trash');
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
