/// Dart side of the sp1 wire protocol: frames the relays must accept, and
/// frames they must reject.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:secretplay/networking/protocol.dart';

void main() {
  test('canonical JSON sorts keys', () {
    expect(canonicalJson({'b': 1, 'a': 2}), '{"a":2,"b":1}');
  });

  test('base64url round-trips without padding', () {
    final encoded = encodeB64u([0, 1, 2, 250, 251, 252]);
    expect(encoded.contains('='), isFalse);
    expect(decodeB64u(encoded), [0, 1, 2, 250, 251, 252]);
  });

  test('decode rejects non url-safe input', () {
    expect(() => decodeB64u('a+b/c='), throwsFormatException);
  });

  test('hello carries the token auth shape', () {
    final frame = Frame.helloToken(
      pairId: 'pair-1234-ABCD',
      deviceId: 'd_abc',
      role: 'A',
      token: 'sp1t.payload.mac',
    );
    expect(frame.data['t'], 'hello');
    expect((frame.data['auth'] as Map)['kind'], 'token');
  });

  test('server frames validate required fields', () {
    final pong = parseServerFrame('{"v":1,"t":"pong","ts":1}');
    expect(pong.isValid, isTrue);

    final badMsg = parseServerFrame('{"v":1,"t":"msg","id":"m_1","cipher":{}}');
    expect(badMsg.isValid, isFalse, reason: 'msg needs a seq');

    final ended = parseServerFrame('{"v":1,"t":"end","reason":"peer_locked"}');
    expect(ended.endReason, 'peer_locked');
  });

  test('oversized frames are rejected', () {
    final huge = '{"v":1,"t":"pong","pad":"${'x' * Protocol.maxFrameBytes}"}';
    expect(parseServerFrame(huge).isValid, isFalse);
  });

  test('pairing payload validation is strict', () {
    final valid = PairingPayload(
      mode: 'local',
      pairId: 'pair-1234',
      invite: 'invite-token',
      expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
      wsUrl: 'ws://192.168.1.10:8787/v1/ws',
      httpUrl: 'http://192.168.1.10:8787',
    );
    final decoded = parsePairingPayload(canonicalJson(valid.toJson()));
    expect(decoded, isNotNull);
    expect(decoded!.isLocal, isTrue);
    expect(decoded.isExpired, isFalse);

    expect(parsePairingPayload('{"v":1}'), isNull);
    expect(parsePairingPayload('not json'), isNull);
  });
}
