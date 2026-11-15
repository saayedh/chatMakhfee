import { test } from 'node:test';
import assert from 'node:assert/strict';

import { RoomMachine, CLOSE_SESSION_ENDED, type SocketLike } from '../../crypto_core/src/room.ts';
import {
  encodeFrame,
  parseClientFrame,
  type CipherEnvelope,
  type ClientFrame,
  type Role,
} from '../../crypto_core/src/frames.ts';
import { b64u, randomBytes } from '../../crypto_core/src/index.ts';

class FakeWs implements SocketLike {
  readonly sent: Array<Record<string, unknown>> = [];
  private closeResult: { code: number; reason: string } | null = null;

  send(data: string): void {
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
  }

  close(code = 1000, reason = ''): void {
    this.closeResult = { code, reason };
  }

  closedCode(): number | null {
    return this.closeResult === null ? null : this.closeResult.code;
  }

  last(type: string): Record<string, unknown> | undefined {
    return [...this.sent].reverse().find((frame) => frame.t === type);
  }
}

function machine(nowRef = { value: 1_000_000 }) {
  const directory = {
    identityFor: (role: Role) => ({ deviceId: `d_${role}`, publicKey: b64u(randomBytes(32)) }),
    isRevoked: () => false,
  };
  const hub = new RoomMachine({
    config: { heartbeatMs: 5000, sessionTimeoutMs: 20_000, ratePerMinute: 240 },
    directory,
    now: () => nowRef.value,
  });
  return { hub, nowRef };
}

function envelope(): CipherEnvelope {
  return {
    senderKey: b64u(randomBytes(32)),
    kind: 1,
    body: b64u(randomBytes(96)),
    msgId: 'm_abc',
    sentAt: 1_000_000,
  };
}

test('the room only relays when both devices are present', () => {
  const { hub } = machine();
  const a = new FakeWs();
  const b = new FakeWs();
  hub.attach({ pairId: 'pair-1', role: 'A', deviceId: 'd_A', socket: a });

  assert.equal(
    hub.handleMessage('pair-1', 'A', JSON.stringify({ v: 1, t: 'msg', id: 'm_1', cipher: envelope() })),
    true,
  );
  assert.equal(a.last('err')?.code, 'session_required');

  hub.attach({ pairId: 'pair-1', role: 'B', deviceId: 'd_B', socket: b });
  hub.handleMessage('pair-1', 'A', JSON.stringify({ v: 1, t: 'msg', id: 'm_1', cipher: envelope() }));
  assert.equal(b.sent.filter((frame) => frame.t === 'msg').length, 1);
});

test('the relayed envelope is byte-identical and never stored', () => {
  const { hub } = machine();
  const a = new FakeWs();
  const b = new FakeWs();
  hub.attach({ pairId: 'pair-1', role: 'A', deviceId: 'd_A', socket: a });
  hub.attach({ pairId: 'pair-1', role: 'B', deviceId: 'd_B', socket: b });

  const cipher = envelope();
  const raw = JSON.stringify({ v: 1, t: 'msg', id: 'm_1', cipher });
  hub.handleMessage('pair-1', 'A', raw);

  const relayed = b.last('msg') as Record<string, unknown>;
  assert.deepEqual(relayed.cipher, cipher);
  assert.equal(relayed.from, 'A');
  assert.equal(relayed.seq, 1);

  const state = JSON.stringify(hub.debugState());
  assert.equal(state.includes(String(cipher.body)), false, 'ciphertext is not retained');
  assert.equal(state.includes('m_1'), false, 'frame ids are not retained in state');
});

test('duplicate frames are rejected, distinct frames are not', () => {
  const { hub } = machine();
  const a = new FakeWs();
  const b = new FakeWs();
  hub.attach({ pairId: 'pair-1', role: 'A', deviceId: 'd_A', socket: a });
  hub.attach({ pairId: 'pair-1', role: 'B', deviceId: 'd_B', socket: b });

  const frame = { v: 1, t: 'msg', id: 'm_dup', cipher: envelope() };
  hub.handleMessage('pair-1', 'A', JSON.stringify(frame));
  hub.handleMessage('pair-1', 'A', JSON.stringify(frame));
  assert.equal(a.last('err')?.code, 'replay');
  assert.equal(b.sent.filter((entry) => entry.t === 'msg').length, 1);
});

test('both devices must be silent for the session to time out', () => {
  const nowRef = { value: 1_000_000 };
  const { hub } = machine(nowRef);
  const a = new FakeWs();
  const b = new FakeWs();
  hub.attach({ pairId: 'pair-1', role: 'A', deviceId: 'd_A', socket: a });
  hub.attach({ pairId: 'pair-1', role: 'B', deviceId: 'd_B', socket: b });

  nowRef.value += 15_000;
  hub.handleMessage('pair-1', 'A', JSON.stringify({ v: 1, t: 'ping', ts: nowRef.value }));
  hub.handleMessage('pair-1', 'B', JSON.stringify({ v: 1, t: 'ping', ts: nowRef.value }));

  nowRef.value += 15_000;
  assert.deepEqual(hub.sweep(), [], 'heartbeats keep the session alive');
  assert.equal(a.last('pong')?.t, 'pong');

  nowRef.value += 30_000;
  assert.deepEqual(hub.sweep(), ['pair-1']);
  assert.equal(a.last('end')?.reason, 'timeout');
  assert.equal(b.last('end')?.reason, 'timeout');
  assert.equal(a.closedCode(), CLOSE_SESSION_ENDED);
  assert.deepEqual(hub.debugState().pairs, []);
});

test('a lock ends the session and tells the peer', () => {
  const { hub } = machine();
  const a = new FakeWs();
  const b = new FakeWs();
  hub.attach({ pairId: 'pair-1', role: 'A', deviceId: 'd_A', socket: a });
  hub.attach({ pairId: 'pair-1', role: 'B', deviceId: 'd_B', socket: b });

  hub.handleMessage('pair-1', 'A', JSON.stringify({ v: 1, t: 'bye', reason: 'lock' }));
  assert.equal(b.last('end')?.reason, 'peer_locked');
  assert.equal(hub.activeSessionCount, 0);
});

test('rehydration reuses the session id and notifies nobody', () => {
  const { hub } = machine();
  const a = new FakeWs();
  const b = new FakeWs();
  const first = hub.attach({ pairId: 'pair-1', role: 'A', deviceId: 'd_A', socket: a });
  const sessionId = first.sessionId;

  const fresh = machine().hub;
  fresh.attach({ pairId: 'pair-1', role: 'B', deviceId: 'd_B', socket: b, sessionId, rehydrate: true });
  const restored = fresh.attach({
    pairId: 'pair-1',
    role: 'A',
    deviceId: 'd_A',
    socket: a,
    sessionId,
    rehydrate: true,
  });
  assert.equal(restored.sessionId, sessionId);
  assert.equal(b.sent.filter((frame) => frame.t === 'peer').length, 0);
});

test('the welcome frame carries the peer identity needed to start Olm', () => {
  const { hub } = machine();
  const a = new FakeWs();
  // The DO sends this frame over the socket; the machine returns it.
  const { welcome } = hub.attach({ pairId: 'pair-1', role: 'A', deviceId: 'd_A', socket: a });
  assert.equal(welcome.peerPresent, false);
  assert.equal((welcome.peer as { deviceId: string }).deviceId, 'd_B');
  assert.equal(welcome.heartbeatMs, 5000);
  assert.equal(welcome.sessionTimeoutMs, 20000);
});

test('relayed frames are valid protocol frames', () => {
  const { hub } = machine();
  const a = new FakeWs();
  const b = new FakeWs();
  hub.attach({ pairId: 'pair-1', role: 'A', deviceId: 'd_A', socket: a });
  hub.attach({ pairId: 'pair-1', role: 'B', deviceId: 'd_B', socket: b });
  const frame: ClientFrame = { v: 1, t: 'signal', id: 's_1', cipher: envelope() };
  hub.handleMessage('pair-1', 'A', encodeFrame(frame));
  const relayed = b.last('signal');
  assert.ok(relayed);
  const parsed = parseClientFrame(JSON.stringify({ ...relayed, t: 'msg' }));
  assert.equal(parsed.ok, true);
});
