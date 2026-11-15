/// Random identifiers.
///
/// Uses [Random.secure] — no `uuid` dependency, no predictable ids. Message and
/// signal ids double as replay-protection keys on the relay, so they must be
/// unguessable and never reused inside a session.
library;

import 'dart:math';

import '../networking/protocol.dart';

final Random _secure = Random.secure();

String randomBase64u(int bytes) {
  final buffer = List<int>.generate(bytes, (_) => _secure.nextInt(256));
  return encodeB64u(buffer);
}

/// A per-frame id: `m_`/`s_` prefix plus 12 random bytes.
String newFrameId({String prefix = 'm'}) => '${prefix}_${randomBase64u(12)}';

/// A device id derived from a public key elsewhere; this is the local random
/// fallback used before identity creation completes.
String newLocalId() => 'l_${randomBase64u(9)}';

/// Short human-readable invitation code for manual entry fallback:
/// four groups of four characters from an unambiguous alphabet.
String newInviteCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final buffer = StringBuffer();
  for (var group = 0; group < 4; group += 1) {
    if (group > 0) buffer.write('-');
    for (var i = 0; i < 4; i += 1) {
      buffer.write(alphabet[_secure.nextInt(alphabet.length)]);
    }
  }
  return buffer.toString();
}
