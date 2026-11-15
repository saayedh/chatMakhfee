/// Session-only invariants on the client.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:secretplay/sessions/session_state.dart';

void main() {
  test('a session is active only when both devices are present', () {
    final machine = SessionMachine();
    machine.start();
    expect(machine.snapshot.phase, SessionPhase.connecting);
    expect(machine.snapshot.canSend, isFalse);

    machine.onWelcome(sessionId: 's_1', peerPresent: false);
    expect(machine.snapshot.phase, SessionPhase.waitingForPeer);
    expect(machine.snapshot.canSend, isFalse);

    machine.onPeerJoined('d_peer');
    expect(machine.snapshot.phase, SessionPhase.active);
    expect(machine.snapshot.canSend, isTrue);
  });

  test('peer leaving drops back to waiting, not idle', () {
    final machine = SessionMachine();
    machine.start();
    machine.onWelcome(sessionId: 's_1', peerPresent: true);
    machine.onPeerLeft();
    expect(machine.snapshot.phase, SessionPhase.waitingForPeer);
    expect(machine.snapshot.canSend, isFalse);
  });

  test('ending clears the session id and forbids sending', () {
    final machine = SessionMachine();
    machine.start();
    machine.onWelcome(sessionId: 's_1', peerPresent: true);
    machine.end(EndReason.peerLocked);
    expect(machine.snapshot.phase, SessionPhase.ended);
    expect(machine.snapshot.sessionId, isNull);
    expect(machine.snapshot.isLocked, isTrue);
    expect(machine.snapshot.canSend, isFalse);
  });

  test('heartbeat timeout is detected after the configured window', () {
    var now = DateTime(2026, 1, 1, 12);
    final machine = SessionMachine(
      heartbeatMs: 5000,
      sessionTimeoutMs: 20000,
      now: () => now,
    );
    machine.start();
    machine.onWelcome(sessionId: 's_1', peerPresent: true);
    expect(machine.timedOut, isFalse);

    now = now.add(const Duration(seconds: 21));
    expect(machine.timedOut, isTrue);

    machine.onPong();
    expect(machine.timedOut, isFalse);
  });

  test('wire reasons map to terminal reasons', () {
    expect(SessionMachine.reasonFromWire('peer_locked'), EndReason.peerLocked);
    expect(SessionMachine.reasonFromWire('revoked'), EndReason.revoked);
    expect(
      SessionMachine.reasonFromWire('anything-else'),
      EndReason.transportError,
    );
  });
}
