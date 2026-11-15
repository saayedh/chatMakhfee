/// Client-side session state machine.
///
/// This is the piece that makes "session only" true on the device: a session
/// exists only between a successful hello and termination; there is no cached
/// transcript to restore, and every terminal transition demands a fresh
/// authentication.
///
/// Pure Dart (no Flutter) so it can be executed by `tool/logic_check.dart`.
library;

enum SessionPhase {
  /// Nothing open. The private area is locked.
  idle,

  /// Socket opening / hello in flight.
  connecting,

  /// Authenticated, waiting for the other device to join.
  waitingForPeer,

  /// Both devices present; messages and signalling are allowed.
  active,

  /// Terminal. The UI must lock and drop all session state.
  ended,
}

enum EndReason {
  none,
  userExit,
  peerLeft,
  peerLocked,
  timeout,
  revoked,
  replaced,
  transportError,
  protocolError,
}

class SessionSnapshot {
  const SessionSnapshot({
    required this.phase,
    required this.reason,
    required this.peerPresent,
    required this.sessionId,
    required this.lastError,
  });

  final SessionPhase phase;
  final EndReason reason;
  final bool peerPresent;
  final String? sessionId;
  final String? lastError;

  bool get canSend => phase == SessionPhase.active && peerPresent;
  bool get isLocked =>
      phase == SessionPhase.idle || phase == SessionPhase.ended;
}

class SessionMachine {
  SessionMachine({
    this.heartbeatMs = 5000,
    this.sessionTimeoutMs = 20000,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int heartbeatMs;
  final int sessionTimeoutMs;
  final DateTime Function() _now;

  SessionPhase _phase = SessionPhase.idle;
  EndReason _reason = EndReason.none;
  bool _peerPresent = false;
  String? _sessionId;
  String? _lastError;
  DateTime? _lastPongAt;
  DateTime? _lastPingAt;

  SessionSnapshot get snapshot => SessionSnapshot(
    phase: _phase,
    reason: _reason,
    peerPresent: _peerPresent,
    sessionId: _sessionId,
    lastError: _lastError,
  );

  bool get needsPing {
    if (_phase != SessionPhase.connecting &&
        _phase != SessionPhase.waitingForPeer &&
        _phase != SessionPhase.active) {
      return false;
    }
    final last = _lastPingAt;
    if (last == null) return true;
    return _now().difference(last).inMilliseconds >= heartbeatMs;
  }

  bool get timedOut {
    if (_phase != SessionPhase.active &&
        _phase != SessionPhase.waitingForPeer) {
      return false;
    }
    final last = _lastPongAt;
    if (last == null) return false;
    return _now().difference(last).inMilliseconds > sessionTimeoutMs;
  }

  void start() {
    if (_phase != SessionPhase.idle && _phase != SessionPhase.ended) return;
    _phase = SessionPhase.connecting;
    _reason = EndReason.none;
    _peerPresent = false;
    _sessionId = null;
    _lastError = null;
    _lastPongAt = null;
    _lastPingAt = null;
  }

  void onWelcome({required String sessionId, required bool peerPresent}) {
    if (_phase != SessionPhase.connecting) return;
    _sessionId = sessionId;
    _peerPresent = peerPresent;
    _phase = peerPresent ? SessionPhase.active : SessionPhase.waitingForPeer;
    _lastPongAt = _now();
  }

  void onPeerJoined(String deviceId) {
    _peerPresent = true;
    if (_phase == SessionPhase.waitingForPeer) _phase = SessionPhase.active;
  }

  void onPeerLeft() {
    _peerPresent = false;
    if (_phase == SessionPhase.active) _phase = SessionPhase.waitingForPeer;
  }

  void onPong() {
    _lastPongAt = _now();
  }

  void onPingSent() {
    _lastPingAt = _now();
  }

  void onRelayed() {
    _lastPongAt = _now();
  }

  void onError(String code, String? detail) {
    _lastError = detail == null ? code : '$code: $detail';
  }

  /// Terminal transition. Always clears session identity.
  void end(EndReason reason) {
    _phase = SessionPhase.ended;
    _reason = reason;
    _peerPresent = false;
    _sessionId = null;
    _lastPingAt = null;
    _lastPongAt = null;
  }

  void reset() {
    _phase = SessionPhase.idle;
    _reason = EndReason.none;
    _peerPresent = false;
    _sessionId = null;
    _lastError = null;
    _lastPingAt = null;
    _lastPongAt = null;
  }

  static EndReason reasonFromWire(String? wire) {
    switch (wire) {
      case 'peer_left':
        return EndReason.peerLeft;
      case 'peer_locked':
        return EndReason.peerLocked;
      case 'timeout':
        return EndReason.timeout;
      case 'revoked':
        return EndReason.revoked;
      case 'replaced':
        return EndReason.replaced;
      case 'server_shutdown':
        return EndReason.transportError;
      case 'protocol_error':
        return EndReason.protocolError;
      default:
        return EndReason.transportError;
    }
  }
}
