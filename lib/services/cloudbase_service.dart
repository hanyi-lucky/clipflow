import 'dart:convert';
import 'package:http/http.dart' as http;

/// 自建服务器 API 封装
class CloudBaseService {
  // 服务器地址（部署后替换为实际 IP）
  static const _baseUrl = 'http://121.196.222.122:3000/api';

  String? _token;
  String? _openId;

  String? get openId => _openId;
  bool get isLoggedIn => _token != null;

  /// 登录/注册
  Future<void> signInAnonymously() async {
    final userId = DateTime.now().millisecondsSinceEpoch.toString();
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

  /// 调用 API
  Future<Map<String, dynamic>> _callApi(String method, String path, {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$_baseUrl$path');
    final headers = {
      'Content-Type': 'application/json',
      if (_token != null) 'Authorization': 'Bearer $_token',
    };

    http.Response response;
    if (method == 'GET') {
      response = await http.get(uri, headers: headers);
    } else if (method == 'POST') {
      response = await http.post(uri, headers: headers, body: jsonEncode(body ?? {}));
    } else if (method == 'PATCH') {
      response = await http.patch(uri, headers: headers, body: jsonEncode(body ?? {}));
    } else if (method == 'DELETE') {
      response = await http.delete(uri, headers: headers);
    } else {
      throw Exception('Unsupported method: $method');
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
