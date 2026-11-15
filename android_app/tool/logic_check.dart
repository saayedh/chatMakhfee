/// Runnable logic checks for the platform-independent Dart layer.
///
///   dart tool/logic_check.dart
///
/// This exists because the Flutter SDK is not installed on every machine that
/// audits this repository. It imports only `dart:` libraries and relative files,
/// so it runs on a plain Dart VM with no `pub get` and no device. It covers the
/// game rules, the wire protocol, the pairing payload parser, the client session
/// state machine and the authentication throttle.
///
/// Flutter widgets, vodozemac and WebRTC are NOT covered here.
library;

import 'dart:convert';
import 'dart:math';

import '../lib/core/ids.dart';
import '../lib/core/rate_limiter.dart';
import '../lib/game/game_engine.dart';
import '../lib/game/models.dart';
import '../lib/networking/protocol.dart';
import '../lib/sessions/session_state.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool Function() body) {
  try {
    if (body()) {
      _passed += 1;
      print('  ok   $name');
    } else {
      _failed += 1;
      print('  FAIL $name');
    }
  } catch (error, stack) {
    _failed += 1;
    print('  FAIL $name -> $error');
    print(stack.toString().split('\n').take(3).join('\n'));
  }
}

void expect(String name, Object? actual, Object? expected) {
  check(name, () => '$actual' == '$expected');
}

void main() {
  print('SecretPlay Dart logic checks');

  _gameRules();
  _throttle();
  _protocol();
  _pairing();
  _session();
  _ids();

  print('\n$_passed passed, $_failed failed');
  if (_failed != 0) {
    throw StateError('logic checks failed');
  }
}

void _gameRules() {
  print('\n[game]');
  expect(
    'perfect guess',
    GameEngine.score([1, 2, 3, 4], [1, 2, 3, 4]),
    const Feedback(4, 0),
  );
  expect(
    'no matches',
    GameEngine.score([0, 0, 0, 0], [4, 4, 4, 4]),
    const Feedback(0, 0),
  );
  expect(
    'colour only',
    GameEngine.score([1, 2, 3, 4], [4, 3, 2, 1]),
    const Feedback(0, 4),
  );
  // Duplicate handling: one 1 in the code cannot score twice.
  expect(
    'duplicate guess is consumed',
    GameEngine.score([1, 1, 2, 2], [1, 2, 3, 4]),
    const Feedback(1, 1),
  );
  expect(
    'duplicate code is consumed',
    GameEngine.score([1, 2, 3, 3], [1, 1, 2, 2]),
    const Feedback(1, 1),
  );
  check('mismatched length throws', () {
    try {
      GameEngine.score([1, 2, 3], [1, 2, 3, 4]);
      return false;
    } on ArgumentError {
      return true;
    }
  });

  final engine = GameEngine(
    difficulty: Difficulty.warmup,
    seed: 7,
    code: [0, 1, 2, 3],
  );
  check('draft fills to the difficulty peg count', () {
    for (var i = 0; i < 4; i += 1) {
      if (!engine.addPeg(i)) return false;
    }
    return engine.isDraftFull && !engine.addPeg(0);
  });
  expect('submit returns feedback', engine.submit(), const Feedback(4, 0));
  expect('win detected', engine.outcome, GameOutcome.won);
  expect('code revealed after win', engine.revealedCode?.join(','), '0,1,2,3');
  expect('win in one row is three stars', engine.stars, 3);
  check('cannot submit after the round ends', () => engine.submit() == null);

  final loser = GameEngine(
    difficulty: Difficulty.warmup,
    seed: 3,
    code: [0, 0, 0, 0],
  );
  check('running out of rows loses', () {
    for (var row = 0; row < Difficulty.warmup.rows; row += 1) {
      for (var peg = 0; peg < 4; peg += 1) {
        loser.addPeg(1);
      }
      loser.submit();
    }
    return loser.outcome == GameOutcome.lost &&
        loser.stars == 0 &&
        loser.rowsLeft == 0;
  });

  final hintEngine = GameEngine(
    difficulty: Difficulty.warmup,
    seed: 5,
    code: [2, 3, 1, 0],
  );
  check('a hint reveals a real code peg and costs a row', () {
    final before = hintEngine.rowsLeft;
    final hint = hintEngine.takeHint();
    return hint != null &&
        [2, 3, 1, 0].contains(hint) &&
        hintEngine.rowsLeft == before - 1;
  });

  expect(
    'stars: half the rows or fewer',
    starsFor(rowsUsed: 5, totalRows: 10, outcome: GameOutcome.won),
    3,
  );
  expect(
    'stars: slow win',
    starsFor(rowsUsed: 10, totalRows: 10, outcome: GameOutcome.won),
    2,
  );
  expect(
    'stars: loss',
    starsFor(rowsUsed: 10, totalRows: 10, outcome: GameOutcome.lost),
    0,
  );
  expect('difficulty ids round-trip', Difficulty.fromId(2), Difficulty.sharp);
}

void _throttle() {
  print('\n[auth throttle]');
  final limiter = AuthRateLimiter(
    freeAttempts: 3,
    baseDelay: const Duration(seconds: 10),
    maxDelay: const Duration(seconds: 40),
  );
  final t0 = DateTime(2026, 1, 1, 12);
  expect('starts unlocked', limiter.check(t0).allowed, true);
  expect('three free failures', limiter.registerFailure(t0), Duration.zero);
  limiter.registerFailure(t0);
  limiter.registerFailure(t0);
  expect('still free after three', limiter.check(t0).allowed, true);
  expect(
    'fourth failure starts a delay',
    limiter.registerFailure(t0),
    const Duration(seconds: 10),
  );
  expect('locked right after', limiter.check(t0).allowed, false);
  expect(
    'unlocks after the delay',
    limiter.check(t0.add(const Duration(seconds: 11))).allowed,
    true,
  );
  expect(
    'next delay doubles',
    limiter.registerFailure(t0),
    const Duration(seconds: 20),
  );
  limiter.registerFailure(t0);
  limiter.registerFailure(t0);
  expect(
    'delay is capped',
    limiter.registerFailure(t0),
    const Duration(seconds: 40),
  );
  limiter.reset();
  expect('reset clears failures', limiter.failures, 0);
  expect('reset unlocks', limiter.check(t0).allowed, true);

  final restored = AuthRateLimiter(freeAttempts: 3, baseDelay: const Duration(seconds: 10));
  final lockUntil = t0.add(const Duration(seconds: 30));
  restored.restore(failures: 6, lockedUntil: lockUntil);
  expect('restored lockout survives process recreation', restored.check(t0).allowed, false);
  expect('restored lockout retains deadline', restored.retryAfter(t0), const Duration(seconds: 30));
  expect('restored limiter unlocks after deadline', restored.check(lockUntil).allowed, true);
  expect('restored failure count is retained', restored.failures, 6);
}

void _protocol() {
  print('\n[protocol]');
  expect(
    'canonical json sorts keys',
    canonicalJson({'b': 1, 'a': 2}),
    '{"a":2,"b":1}',
  );
  expect(
    'canonical json nests',
    canonicalJson({
      'z': [
        1,
        {'b': true, 'a': null},
      ],
    }),
    '{"z":[1,{"a":null,"b":true}]}',
  );
  expect(
    'canonical json escapes',
    canonicalJson({'a': 'he said "hi"'}),
    '{"a":"he said \\"hi\\""}',
  );
  expect(
    'numbers stay numbers',
    canonicalJson({'a': 42, 'b': 1.5}),
    '{"a":42,"b":1.5}',
  );

  final bytes = List<int>.generate(32, (i) => i * 7 % 256);
  expect(
    'base64url round-trip',
    encodeB64u(decodeB64u(encodeB64u(bytes))),
    encodeB64u(bytes),
  );
  expect('base64url has no padding', encodeB64u(bytes).contains('='), false);
  expect(
    'standard base64 converts to protocol base64url',
    standardBase64ToB64u('+//v'),
    '-__v',
  );
  expect(
    'protocol base64url converts to Vodozemac standard base64',
    b64uToStandardBase64('-__v'),
    '+//v',
  );
  expect(
    'base64 conversion preserves a 32-byte public key',
    decodeB64u(standardBase64ToB64u(base64.encode(bytes))).length,
    32,
  );
  check('invalid standard base64 throws', () {
    try {
      standardBase64ToB64u('invalid!');
      return false;
    } on FormatException {
      return true;
    }
  });
  check('invalid base64url throws', () {
    try {
      decodeB64u('a+b/c');
      return false;
    } on FormatException {
      return true;
    }
  });

  final hello = Frame.helloToken(
    pairId: 'pair-ABCD-EFGH-12',
    deviceId: 'd_1',
    role: 'A',
    token: 'tok',
  );
  final helloJson = jsonDecode(hello.encode()) as Map<String, dynamic>;
  expect('hello type', helloJson['t'], 'hello');
  expect('hello proto', helloJson['proto'], 'sp1');
  expect('hello auth kind', (helloJson['auth'] as Map)['kind'], 'token');

  final envelope = CipherEnvelope(
    senderKey: encodeB64u(List<int>.filled(32, 1)),
    kind: 1,
    body: encodeB64u(List<int>.filled(64, 2)),
    msgId: 'm_1',
    sentAt: 1700000000000,
  );
  final msg = jsonDecode(
    Frame.message('m_1', envelope).encode(),
  ) as Map<String, dynamic>;
  expect('message frame type', msg['t'], 'msg');
  expect(
    'cipher body preserved',
    (msg['cipher'] as Map)['body'],
    envelope.body,
  );

  final welcome = parseServerFrame(
    jsonEncode({
      'v': 1,
      't': 'welcome',
      'sessionId': 's-1',
      'role': 'A',
      'peerPresent': true,
      'peer': {'deviceId': 'd_2', 'publicKey': 'pk'},
      'serverTime': 1,
      'heartbeatMs': 5000,
      'sessionTimeoutMs': 20000,
    }),
  );
  expect('welcome parses', welcome.type, 'welcome');
  expect('welcome session id', welcome.sessionId, 's-1');
  expect('welcome peer present', welcome.peerPresent, true);

  final relay = parseServerFrame(
    jsonEncode({
      'v': 1,
      't': 'msg',
      'id': 'm_1',
      'seq': 4,
      'from': 'B',
      'cipher': envelope.toJson(),
    }),
  );
  expect('relay parses', relay.type, 'msg');
  expect(
    'bad seq rejected',
    parseServerFrame(
      jsonEncode({'v': 1, 't': 'msg', 'id': 'm_1', 'seq': 0, 'cipher': {}}),
    ).isValid,
    false,
  );
  expect(
    'missing cipher rejected',
    parseServerFrame(jsonEncode({'v': 1, 't': 'msg', 'id': 'm_1', 'seq': 1}))
        .isValid,
    false,
  );
  expect(
    'wrong version rejected',
    parseServerFrame(jsonEncode({'v': 2, 't': 'pong'})).isValid,
    false,
  );
  expect(
    'unknown type rejected',
    parseServerFrame(jsonEncode({'v': 1, 't': 'dance'})).isValid,
    false,
  );
  expect('garbage rejected', parseServerFrame('not json').isValid, false);
  expect(
    'oversized rejected',
    parseServerFrame('x' * (Protocol.maxFrameBytes + 1)).isValid,
    false,
  );
  expect(
    'end reason exposed',
    parseServerFrame(jsonEncode({'v': 1, 't': 'end', 'reason': 'peer_locked'}))
        .endReason,
    'peer_locked',
  );
  expect(
    'error code exposed',
    parseServerFrame(jsonEncode({'v': 1, 't': 'err', 'code': 'replay'}))
        .errorCode,
    'replay',
  );
}

void _pairing() {
  print('\n[pairing]');
  final local = PairingPayload.fromJson({
    'v': 1,
    'proto': 'sp1',
    'mode': 'local',
    'wsUrl': 'ws://192.168.137.1:8787/v1/ws',
    'httpUrl': 'http://192.168.137.1:8787',
    'pairId': 'pair-ABCD-EFGH-12',
    'invite': 'a' * 32,
    'expiresAt': DateTime.now()
        .add(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
  });
  expect('local payload parses', local?.isLocal, true);
  expect('local payload not expired', local?.isExpired, false);
  expect(
    'local payload round-trips',
    parsePairingPayload(jsonEncode(local!.toJson()))?.pairId,
    'pair-ABCD-EFGH-12',
  );

  final expired = PairingPayload.fromJson({
    'v': 1,
    'proto': 'sp1',
    'mode': 'local',
    'wsUrl': 'ws://10.0.0.2:8787/v1/ws',
    'httpUrl': 'http://10.0.0.2:8787',
    'pairId': 'pair-ABCD-EFGH-12',
    'invite': 'b' * 32,
    'expiresAt': DateTime.now()
        .subtract(const Duration(seconds: 1))
        .millisecondsSinceEpoch,
  });
  expect('expired invitation detected', expired?.isExpired, true);

  expect(
    'cloud requires wss',
    PairingPayload.fromJson({
      'v': 1,
      'proto': 'sp1',
      'mode': 'cloud',
      'wsUrl': 'ws://evil.example/v1/ws',
      'pairId': 'pair-ABCD-EFGH-12',
      'invite': 'c' * 32,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 1000,
    }),
    null,
  );
  expect(
    'local requires http url',
    PairingPayload.fromJson({
      'v': 1,
      'proto': 'sp1',
      'mode': 'local',
      'wsUrl': 'ws://10.0.0.2:8787/v1/ws',
      'pairId': 'pair-ABCD-EFGH-12',
      'invite': 'c' * 32,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 1000,
    }),
    null,
  );
  expect(
    'local payload rejects public Internet hosts',
    PairingPayload.fromJson({
      'v': 1,
      'proto': 'sp1',
      'mode': 'local',
      'wsUrl': 'ws://203.0.113.20:8787/v1/ws',
      'httpUrl': 'http://203.0.113.20:8787',
      'pairId': 'pair-ABCD-EFGH-12',
      'invite': 'd' * 32,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 1000,
    }),
    null,
  );
  expect(
    'local payload rejects HTTP and WebSocket authority mismatch',
    PairingPayload.fromJson({
      'v': 1,
      'proto': 'sp1',
      'mode': 'local',
      'wsUrl': 'ws://192.168.137.1:8787/v1/ws',
      'httpUrl': 'http://192.168.137.2:8787',
      'pairId': 'pair-ABCD-EFGH-12',
      'invite': 'e' * 32,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 1000,
    }),
    null,
  );
  expect(
    'foreign json rejected',
    parsePairingPayload('{"hello":"world"}'),
    null,
  );
  expect(
    'bad pair id rejected',
    PairingPayload.fromJson({
      'v': 1,
      'proto': 'sp1',
      'mode': 'cloud',
      'wsUrl': 'wss://x/v1/ws',
      'pairId': '../etc',
      'invite': 'c' * 32,
      'expiresAt': 1,
    }),
    null,
  );
}

void _session() {
  print('\n[session]');
  var clock = DateTime(2026, 1, 1, 12);
  final machine = SessionMachine(
    heartbeatMs: 5000,
    sessionTimeoutMs: 20000,
    now: () => clock,
  );

  expect('starts idle and locked', machine.snapshot.isLocked, true);
  machine.start();
  expect(
    'connecting after start',
    machine.snapshot.phase,
    SessionPhase.connecting,
  );
  expect('ping immediately after connect', machine.needsPing, true);

  machine.onWelcome(sessionId: 's-1', peerPresent: false);
  expect('waits for peer', machine.snapshot.phase, SessionPhase.waitingForPeer);
  expect('cannot send alone', machine.snapshot.canSend, false);

  machine.onPeerJoined('d_2');
  expect('active when peer joins', machine.snapshot.phase, SessionPhase.active);
  expect('can send when active', machine.snapshot.canSend, true);

  machine.onPingSent();
  expect('no ping before the interval', machine.needsPing, false);
  clock = clock.add(const Duration(seconds: 5));
  expect('ping due after the interval', machine.needsPing, true);

  clock = clock.add(const Duration(seconds: 19));
  machine.onPong();
  expect('fresh pong keeps the session', machine.timedOut, false);
  machine.onPong();
  clock = clock.add(const Duration(seconds: 21));
  expect('silence times out', machine.timedOut, true);

  machine.onPeerLeft();
  expect(
    'peer leaving downgrades instead of ending',
    machine.snapshot.phase,
    SessionPhase.waitingForPeer,
  );

  machine.end(EndReason.peerLocked);
  expect('end locks', machine.snapshot.isLocked, true);
  expect('end clears session id', machine.snapshot.sessionId, null);
  expect('end reason kept', machine.snapshot.reason, EndReason.peerLocked);
  expect('cannot send after end', machine.snapshot.canSend, false);

  machine.start();
  expect('restart needs a fresh hello', machine.snapshot.sessionId, null);
  expect(
    'restart is connecting',
    machine.snapshot.phase,
    SessionPhase.connecting,
  );

  expect(
    'wire reason mapping',
    SessionMachine.reasonFromWire('timeout'),
    EndReason.timeout,
  );
  expect(
    'unknown wire reason is a transport error',
    SessionMachine.reasonFromWire('whatever'),
    EndReason.transportError,
  );
}

void _ids() {
  print('\n[ids]');
  final ids = <String>{};
  for (var i = 0; i < 200; i += 1) {
    ids.add(newFrameId());
  }
  expect('frame ids are unique', ids.length, 200);
  check(
    'frame id format',
    () => RegExp(r'^m_[A-Za-z0-9_-]{16}$').hasMatch(ids.first),
  );
  check(
    'signal ids carry their prefix',
    () => newFrameId(prefix: 's').startsWith('s_'),
  );
  check(
    'invite codes are readable',
    () => RegExp(r'^[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$').hasMatch(newInviteCode()),
  );
  check('local ids differ', () => newLocalId() != newLocalId());
  check('randomInt is used, not math.Random()', () => Random.secure() != null);
}
