/// sp1 wire protocol, Dart side.
///
/// Mirrors `crypto_core/src/frames.ts` exactly; the two relays reject anything
/// that does not match these rules. Pure Dart (no package imports) so
/// `tool/logic_check.dart` can execute the validators directly.
library;

import 'dart:convert';

class Protocol {
  const Protocol._();

  static const int version = 1;
  static const String id = 'sp1';
  static const int maxFrameBytes = 16 * 1024;
  static const int maxCipherBodyBytes = 8 * 1024;
  static const String closeSessionEndedCode = 'session_ended';
}

/// Base64url without padding, matching the relay's expectations.
String encodeB64u(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Strict base64url decode. Throws [FormatException] on invalid input so
/// callers can reject a frame instead of crashing the socket.
List<int> decodeB64u(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(value)) {
    throw const FormatException('not url-safe base64');
  }
  final padding = value.length % 4 == 0 ? '' : '=' * (4 - value.length % 4);
  return base64Url.decode(value + padding);
}

/// Convert the standard Base64 representation emitted by Vodozemac into the
/// unpadded Base64URL representation required by the SecretPlay wire protocol.
/// Conversion goes through bytes so alphabet and padding differences cannot
/// leak into signatures, public-key validation or ciphertext envelopes.
String standardBase64ToB64u(String value) {
  if (!RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(value)) {
    throw const FormatException('not standard base64');
  }
  final unpadded = value.replaceAll('=', '');
  if (unpadded.length % 4 == 1) {
    throw const FormatException('invalid standard base64 length');
  }
  final padding = unpadded.length % 4 == 0
      ? ''
      : '=' * (4 - unpadded.length % 4);
  final bytes = base64.decode(unpadded + padding);
  return encodeB64u(bytes);
}

/// Convert a strict SecretPlay Base64URL value into padded standard Base64 for
/// Vodozemac APIs, which accept standard Base64 strings.
String b64uToStandardBase64(String value) => base64.encode(decodeB64u(value));

/// Deterministic JSON with sorted object keys, matching the TypeScript side.
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  void write(Object? node) {
    if (node == null) {
      buffer.write('null');
    } else if (node is String) {
      buffer.write(jsonEncode(node));
    } else if (node is num) {
      if (node is double && (!node.isFinite)) {
        throw const FormatException('non-finite numbers are not allowed');
      }
      buffer.write(
        node is double && node == node.roundToDouble()
            ? node.toStringAsFixed(0)
            : node.toString(),
      );
    } else if (node is bool) {
      buffer.write(node ? 'true' : 'false');
    } else if (node is List) {
      buffer.write('[');
      for (var i = 0; i < node.length; i += 1) {
        if (i > 0) buffer.write(',');
        write(node[i]);
      }
      buffer.write(']');
    } else if (node is Map) {
      final keys = node.keys.map((key) => key.toString()).toList()..sort();
      buffer.write('{');
      var first = true;
      for (final key in keys) {
        // JSON null is meaningful and must be preserved (only `undefined` was
        // dropped on the TypeScript side, and Dart has no undefined).
        final entry = node[key];
        if (!first) buffer.write(',');
        first = false;
        buffer.write(jsonEncode(key));
        buffer.write(':');
        write(entry);
      }
      buffer.write('}');
    } else {
      throw FormatException('unsupported value type ${node.runtimeType}');
    }
  }

  write(value);
  return buffer.toString();
}

/// An opaque Olm envelope. The relay never inspects [body].
class CipherEnvelope {
  const CipherEnvelope({
    required this.senderKey,
    required this.kind,
    required this.body,
    required this.msgId,
    required this.sentAt,
  });

  final String senderKey;
  final int kind;
  final String body;
  final String msgId;
  final int sentAt;

  Map<String, dynamic> toJson() => {
    'senderKey': senderKey,
    'kind': kind,
    'body': body,
    'msgId': msgId,
    'sentAt': sentAt,
  };

  static CipherEnvelope fromJson(Map<String, dynamic> json) => CipherEnvelope(
    senderKey: json['senderKey'] as String,
    kind: json['kind'] as int,
    body: json['body'] as String,
    msgId: json['msgId'] as String,
    sentAt: json['sentAt'] as int,
  );
}

class Frame {
  const Frame(this.data);

  final Map<String, dynamic> data;

  String encode() => jsonEncode(data);

  static Frame helloToken({
    required String pairId,
    required String deviceId,
    required String role,
    required String token,
  }) => Frame({
    'v': Protocol.version,
    't': 'hello',
    'proto': Protocol.id,
    'pairId': pairId,
    'deviceId': deviceId,
    'role': role,
    'auth': {'kind': 'token', 'token': token},
  });

  static Frame helloSigned({
    required String pairId,
    required String deviceId,
    required String role,
    required int ts,
    required String nonce,
    required String signature,
    required Map<String, String> olm,
  }) => Frame({
    'v': Protocol.version,
    't': 'hello',
    'proto': Protocol.id,
    'pairId': pairId,
    'deviceId': deviceId,
    'role': role,
    'auth': {'kind': 'signed', 'ts': ts, 'nonce': nonce, 'sig': signature},
    'olm': olm,
  });

  static Frame message(String id, CipherEnvelope cipher) => Frame({
    'v': Protocol.version,
    't': 'msg',
    'id': id,
    'cipher': cipher.toJson(),
  });

  static Frame signal(String id, CipherEnvelope cipher) => Frame({
    'v': Protocol.version,
    't': 'signal',
    'id': id,
    'cipher': cipher.toJson(),
  });

  static Frame ping(int ts) =>
      Frame({'v': Protocol.version, 't': 'ping', 'ts': ts});

  static Frame bye(String reason) =>
      Frame({'v': Protocol.version, 't': 'bye', 'reason': reason});
}

/// A parsed server frame. Unknown or malformed frames produce `type == 'invalid'`
/// so callers can surface a protocol error instead of guessing.
class ServerFrame {
  const ServerFrame(this.type, this.data);

  final String type;
  final Map<String, dynamic> data;

  bool get isValid => type != 'invalid';

  String? get errorCode => type == 'err' ? data['code'] as String? : null;
  String? get endReason => type == 'end' ? data['reason'] as String? : null;
  bool get peerPresent => data['peerPresent'] == true;
  String? get sessionId => data['sessionId'] as String?;
}

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

ServerFrame parseServerFrame(String raw) {
  if (raw.isEmpty || raw.length > Protocol.maxFrameBytes) {
    return const ServerFrame('invalid', {});
  }
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const ServerFrame('invalid', {});
  }
  if (decoded is! Map<String, dynamic>) return const ServerFrame('invalid', {});
  if (decoded['v'] != Protocol.version) return const ServerFrame('invalid', {});

  final type = decoded['t'];
  if (type is! String) return const ServerFrame('invalid', {});

  switch (type) {
    case 'welcome':
      if (decoded['sessionId'] is! String || decoded['role'] is! String) {
        return const ServerFrame('invalid', {});
      }
      return ServerFrame(type, decoded);
    case 'peer':
      if (decoded['state'] != 'joined' && decoded['state'] != 'left') {
        return const ServerFrame('invalid', {});
      }
      return ServerFrame(type, decoded);
    case 'msg':
    case 'signal':
      if (!_idPattern.hasMatch('${decoded['id']}'))
        return const ServerFrame('invalid', {});
      if (decoded['cipher'] is! Map) return const ServerFrame('invalid', {});
      final seq = decoded['seq'];
      if (seq is! int || seq < 1) return const ServerFrame('invalid', {});
      return ServerFrame(type, decoded);
    case 'pong':
      return ServerFrame(type, decoded);
    case 'end':
      if (decoded['reason'] is! String) return const ServerFrame('invalid', {});
      return ServerFrame(type, decoded);
    case 'err':
      if (decoded['code'] is! String) return const ServerFrame('invalid', {});
      return ServerFrame(type, decoded);
    default:
      return const ServerFrame('invalid', {});
  }
}

/// Validate a pairing QR payload. Returns null when anything is off, so the
/// scanner can show a plain "this is not a SecretPlay code" message.
PairingPayload? parsePairingPayload(String raw) {
  if (raw.isEmpty || raw.length > 2048) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  return PairingPayload.fromJson(decoded);
}

bool _isPrivateIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    octets.add(value);
  }
  final a = octets[0];
  final b = octets[1];
  return a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254);
}

class PairingPayload {
  const PairingPayload({
    required this.mode,
    required this.pairId,
    required this.invite,
    required this.expiresAt,
    required this.wsUrl,
    this.httpUrl,
  });

  final String mode; // 'local' | 'cloud'
  final String pairId;
  final String invite;
  final int expiresAt;
  final String wsUrl;
  final String? httpUrl;

  bool get isLocal => mode == 'local';

  bool get isExpired => DateTime.now().millisecondsSinceEpoch >= expiresAt;

  static PairingPayload? fromJson(Map<String, dynamic> json) {
    if (json['v'] != Protocol.version || json['proto'] != Protocol.id)
      return null;
    final mode = json['mode'];
    if (mode != 'local' && mode != 'cloud') return null;
    final pairId = json['pairId'];
    final invite = json['invite'];
    final wsUrl = json['wsUrl'];
    final expiresAt = json['expiresAt'];
    if (pairId is! String || !RegExp(r'^[A-Za-z0-9_-]{6,40}$').hasMatch(pairId))
      return null;
    if (invite is! String || invite.isEmpty || invite.length > 128) return null;
    if (wsUrl is! String) return null;
    if (expiresAt is! int) return null;
    if (mode == 'local') {
      final wsUri = Uri.tryParse(wsUrl);
      final httpUrl = json['httpUrl'];
      final httpUri = httpUrl is String ? Uri.tryParse(httpUrl) : null;
      if (wsUri == null ||
          httpUri == null ||
          wsUri.scheme != 'ws' ||
          httpUri.scheme != 'http' ||
          !_isPrivateIpv4(wsUri.host) ||
          wsUri.host != httpUri.host ||
          wsUri.port != httpUri.port ||
          wsUri.path != '/v1/ws' ||
          httpUri.path.isNotEmpty ||
          wsUri.userInfo.isNotEmpty ||
          httpUri.userInfo.isNotEmpty ||
          wsUri.hasQuery ||
          httpUri.hasQuery ||
          wsUri.hasFragment ||
          httpUri.hasFragment) {
        return null;
      }
      return PairingPayload(
        mode: mode as String,
        pairId: pairId,
        invite: invite,
        expiresAt: expiresAt,
        wsUrl: wsUrl,
        httpUrl: httpUrl,
      );
    }
    if (!wsUrl.startsWith('wss://')) return null;
    return PairingPayload(
      mode: mode as String,
      pairId: pairId,
      invite: invite,
      expiresAt: expiresAt,
      wsUrl: wsUrl,
    );
  }

  Map<String, dynamic> toJson() => {
    'v': Protocol.version,
    'proto': Protocol.id,
    'mode': mode,
    'wsUrl': wsUrl,
    if (httpUrl != null) 'httpUrl': httpUrl,
    'pairId': pairId,
    'invite': invite,
    'expiresAt': expiresAt,
  };
}
