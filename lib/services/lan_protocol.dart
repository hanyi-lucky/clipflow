import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/constants.dart';

/// LAN 帧协议错误（版本不匹配 / 超长 / 畸形 / 读超时 / 断链）。
class LanProtocolException implements Exception {
  final String message;
  LanProtocolException(this.message);

  @override
  String toString() => 'LanProtocolException: $message';
}

/// 帧格式：`[4 字节大端长度头][UTF-8 JSON 载荷]`。
///
/// - 每个 JSON 载荷必须携带 `v`（协议版本，见 [LanConstants.lanProtoVersion]）。
/// - 帧上限 [LanConstants.lanMaxFrameBytes]（16MiB），超长直接拒帧。
///
/// 该模块只负责帧的编解码与 socket 收发；报文内容语义（Hello/auth 等）
/// 由 `lan_handshake_service.dart` 定义。
Uint8List encodeFrame(Map<String, dynamic> message) {
  final payload = utf8.encode(jsonEncode(message));
  if (payload.length > LanConstants.lanMaxFrameBytes) {
    throw LanProtocolException(
      'frame payload ${payload.length} bytes exceeds max '
      '${LanConstants.lanMaxFrameBytes}',
    );
  }
  final bytes = Uint8List(4 + payload.length);
  ByteData.sublistView(bytes).setUint32(0, payload.length);
  bytes.setRange(4, bytes.length, payload);
  return bytes;
}

/// 解码完整帧字节（长度头 + 载荷）。校验长度上限、JSON 结构、协议版本。
Map<String, dynamic> decodeFrameBytes(Uint8List bytes) {
  if (bytes.length < 4) {
    throw LanProtocolException('frame shorter than length header');
  }
  final length = ByteData.sublistView(bytes).getUint32(0);
  if (length > LanConstants.lanMaxFrameBytes) {
    throw LanProtocolException(
      'frame declares $length bytes, exceeds max ${LanConstants.lanMaxFrameBytes}',
    );
  }
  if (bytes.length != 4 + length) {
    throw LanProtocolException(
      'frame length mismatch: header says $length, got ${bytes.length - 4}',
    );
  }
  if (length == 0) {
    throw LanProtocolException('empty frame');
  }
  final String jsonString;
  try {
    jsonString = utf8.decode(bytes.sublist(4));
  } catch (_) {
    throw LanProtocolException('frame payload is not valid UTF-8');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonString);
  } catch (_) {
    throw LanProtocolException('frame payload is not valid JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw LanProtocolException('frame payload is not a JSON object');
  }
  if (decoded['v'] != LanConstants.lanProtoVersion) {
    throw LanProtocolException(
      'unsupported protocol version: ${decoded['v']} '
      '(expected ${LanConstants.lanProtoVersion})',
    );
  }
  return decoded;
}

/// 向 [socket] 写入一帧（非阻塞，交由 socket 背压）。
void writeFrame(Socket socket, Map<String, dynamic> message) {
  socket.add(encodeFrame(message));
}

/// 从 [socket] 读取一帧。
///
/// [timeout] 作用于整帧读取（空闲超时）。断链 / 超时 / 协议错误统一抛
/// [LanProtocolException]（调用方按「只断单个 session」处理）。
Future<Map<String, dynamic>> readFrame(
  Socket socket, {
  Duration? timeout,
}) async {
  final source = timeout == null ? socket : socket.timeout(timeout);
  final reader = _SocketFrameReader(source);
  try {
    final header = await reader.read(4);
    final length = ByteData.sublistView(header).getUint32(0);
    if (length > LanConstants.lanMaxFrameBytes) {
      throw LanProtocolException(
        'frame declares $length bytes, exceeds max ${LanConstants.lanMaxFrameBytes}',
      );
    }
    final payload = await reader.read(length);
    final bytes = Uint8List(4 + length);
    bytes.setRange(0, 4, header);
    bytes.setRange(4, bytes.length, payload);
    return decodeFrameBytes(bytes);
  } on TimeoutException {
    throw LanProtocolException('frame read timed out');
  } on SocketException catch (e) {
    throw LanProtocolException('socket error: ${e.message}');
  }
}

/// 带缓冲的 socket 精确读取（`Socket` 本身是 `Stream<Uint8List>`，用
/// `StreamIterator` 拉取 chunk，可处理一次 read 返回超长 chunk 的情况）。
class _SocketFrameReader {
  _SocketFrameReader(Stream<Uint8List> socket)
      : _iterator = StreamIterator<Uint8List>(socket);

  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = [];

  Future<Uint8List> read(int length) async {
    while (_buffer.length < length) {
      if (!await _iterator.moveNext()) {
        throw LanProtocolException('socket closed before frame completed');
      }
      _buffer.addAll(_iterator.current);
    }
    final result = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer.removeRange(0, length);
    return result;
  }
}
