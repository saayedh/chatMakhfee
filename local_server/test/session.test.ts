import { test } from 'node:test';
import assert from 'node:assert/strict';

import { SessionHub, CLOSE_SESSION_ENDED, type SocketLike } from '../src/session.ts';
import type { PeerIdentity } from '../../crypto_core/src/index.ts';
import {
  helloFrame,
  idle,
  registerPair,
  startRelay,
  TestClient,
  type TestRelay,
} from './support/relay.ts';

class FakeSocket implements SocketLike {
  readonly sent: string[] = [];
  private closeResult: { code: number; reason: string } | null = null;

  send(data: string): void {
    this.sent.push(data);
  }

  close(code = 1000, reason = ''): void {
    this.closeResult = { code, reason };
  }

  closedCode(): number | null {
    return this.closeResult === null ? null : this.closeResult.code;
  }

  frames(): Array<Record<string, unknown>> {
    return this.sent.map((raw) => JSON.parse(raw) as Record<string, unknown>);
  }
}

function makeHub(nowRef: { value: number }) {
  const directory = {
    identityFor(role: 'A' | 'B'): PeerIdentity | null {
      return { deviceId: `d_${role}`, publicKey: `pk_${role}` };
    },
    isRevoked: () => false,
  };
  return new SessionHub({
    config: { heartbeatMs: 1000, sessionTimeoutMs: 1000, ratePerMinute: 100 },
    directory,
    now: () => nowRef.value,
  });
}

test('heartbeat silence ends the session for both devices', () => {
  const clock = { value: 1_000_000 };
  const hub = makeHub(clock);
  const socketA = new FakeSocket();
  const socketB = new FakeSocket();
  hub.attach({ pairId: 'pair-test', role: 'A', deviceId: 'd_A', socket: socketA });
  hub.attach({ pairId: 'pair-test', role: 'B', deviceId: 'd_B', socket: socketB });

  clock.value += 500;
  assert.deepEqual(hub.sweep(), [], 'a fresh session is not swept');
  assert.equal(socketA.closedCode(), null);

  clock.value += 1_500;
  const ended = hub.sweep();
  assert.deepEqual(ended, ['pair-test']);
  assert.equal(socketA.closedCode(), CLOSE_SESSION_ENDED);
  assert.equal(socketB.closedCode(), CLOSE_SESSION_ENDED);
  for (const socket of [socketA, socketB]) {
    const end = socket.frames().find((frame) => frame.t === 'end');
    assert.equal(end?.reason, 'timeout');
  }
  assert.deepEqual(hub.debugState().pairs, [], 'the runtime is deleted, not paused');
});

test('a heartbeat before the timeout keeps the session alive', () => {
  const clock = { value: 1_000_000 };
  const hub = makeHub(clock);
  const socketA = new FakeSocket();
  const socketB = new FakeSocket();
  hub.attach({ pairId: 'pair-test', role: 'A', deviceId: 'd_A', socket: socketA });
  hub.attach({ pairId: 'pair-test', role: 'B', deviceId: 'd_B', socket: socketB });

  for (let tick = 0; tick < 5; tick += 1) {
    clock.value += 800;
    hub.handleMessage('pair-test', 'A', JSON.stringify({ v: 1, t: 'ping', ts: clock.value }));
    hub.handleMessage('pair-test', 'B', JSON.stringify({ v: 1, t: 'ping', ts: clock.value }));
    assert.deepEqual(hub.sweep(), []);
  }
  assert.equal(socketA.closedCode(), null);
  assert.equal(socketB.closedCode(), null);
});

test('bye ends the session for the peer and clears all state', async () => {
  const relay = await startRelay();
  try {
    const pair = await registerPair(relay);
    const pairId = relay.server.store.pairId;
    const url = `ws://127.0.0.1:${relay.port}/v1/ws`;
    const a = await TestClient.connect(
      url,
      helloFrame({ token: pair.tokenA, pairId, deviceId: pair.deviceA.deviceId, role: 'A' }),
      'A',
    );
    const b = await TestClient.connect(
      url,
      helloFrame({ token: pair.tokenB, pairId, deviceId: pair.deviceB.deviceId, role: 'B' }),
      'B',
    );
    await a.next('welcome');
    await b.next('welcome');
    await a.next('peer');

    a.send({ v: 1, t: 'bye', reason: 'user_exit' });
    const end = await b.next('end');
    assert.equal(end.reason, 'peer_left');
    await b.waitClosed();
    await a.waitClosed();
    await idle(150);
    assert.deepEqual(relay.server.hub.debugState().pairs, []);
    assert.equal(relay.server.hub.activeSessionCount, 0);
  } finally {
    await relay.close();
  }
});

test('locking tells the peer the session was locked', async () => {
  const relay = await startRelay();
  try {
    const pair = await registerPair(relay);
    const pairId = relay.server.store.pairId;
    const url = `ws://127.0.0.1:${relay.port}/v1/ws`;
    const a = await TestClient.connect(
      url,
      helloFrame({ token: pair.tokenA, pairId, deviceId: pair.deviceA.deviceId, role: 'A' }),
      'A',
    );
    const b = await TestClient.connect(
      url,
      helloFrame({ token: pair.tokenB, pairId, deviceId: pair.deviceB.deviceId, role: 'B' }),
      'B',
    );
    await a.next('welcome');
    await b.next('welcome');
    a.send({ v: 1, t: 'bye', reason: 'lock' });
    const end = await b.next('end');
    assert.equal(end.reason, 'peer_locked');
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});

test('dropping the socket immediately terminates the session for the peer', async () => {
  const relay = await startRelay();
  try {
    const pair = await registerPair(relay);
    const pairId = relay.server.store.pairId;
    const url = `ws://127.0.0.1:${relay.port}/v1/ws`;
    const a = await TestClient.connect(
      url,
      helloFrame({ token: pair.tokenA, pairId, deviceId: pair.deviceA.deviceId, role: 'A' }),
      'A',
    );
    const b = await TestClient.connect(
      url,
      helloFrame({ token: pair.tokenB, pairId, deviceId: pair.deviceB.deviceId, role: 'B' }),
      'B',
    );
    await a.next('welcome');
    await b.next('welcome');
    a.close();
    const end = await b.next('end');
    assert.equal(end.reason, 'peer_left');
    b.close();
  } finally {
    await relay.close();
  }
});

test('restarting the relay destroys pairs, tokens and any session state', async () => {
  const first: TestRelay = await startRelay();
  const pair = await registerPair(first);
  const pairId = first.server.store.pairId;
  const url = `ws://127.0.0.1:${first.port}/v1/ws`;
  const a = await TestClient.connect(
    url,
    helloFrame({ token: pair.tokenA, pairId, deviceId: pair.deviceA.deviceId, role: 'A' }),
    'A',
  );
  const b = await TestClient.connect(
    url,
    helloFrame({ token: pair.tokenB, pairId, deviceId: pair.deviceB.deviceId, role: 'B' }),
    'B',
  );
  await a.next('welcome');
  await b.next('welcome');
  await first.close();

  const second = await startRelay();
  try {
    assert.equal(second.server.store.slotsFilled, 0, 'no pair survives a restart');
    assert.equal(second.server.hub.activeSessionCount, 0);
    assert.notEqual(second.server.store.pairId, pairId);

    const reconnect = await TestClient.connect(
      `ws://127.0.0.1:${second.port}/v1/ws`,
      helloFrame({ token: pair.tokenA, pairId, deviceId: pair.deviceA.deviceId, role: 'A' }),
      'reconnect',
    );
    const err = await reconnect.next('err');
    assert.ok(['unauthorized', 'pair_unknown', 'device_revoked'].includes(String(err.code)));
    await reconnect.waitClosed();
  } finally {
    await second.close();
  }
});
