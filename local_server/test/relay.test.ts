import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  helloFrame,
  helloWithOlm,
  idle,
  msgFrame,
  registerPair,
  startRelay,
  TestClient,
  type TestRelay,
} from './support/relay.ts';
import { open, seal, tamper } from './support/codec.ts';
import { b64u, randomBytes, type CipherEnvelope } from '../../crypto_core/src/index.ts';

const SECRET = 'meet me at the arcade at eight';

async function connectBoth(relay: TestRelay) {
  const pair = await registerPair(relay);
  const pairId = relay.server.store.pairId;
  const url = `ws://127.0.0.1:${relay.port}/v1/ws`;
  const a = await TestClient.connect(
    url,
    helloFrame({ token: pair.tokenA, pairId, deviceId: pair.deviceA.deviceId, role: 'A' }),
    'A',
  );
  const welcomeA = await a.next('welcome');
  const b = await TestClient.connect(
    url,
    helloFrame({ token: pair.tokenB, pairId, deviceId: pair.deviceB.deviceId, role: 'B' }),
    'B',
  );
  const welcomeB = await b.next('welcome');
  return { pair, a, b, welcomeA, welcomeB, pairId };
}

test('both devices see each other and the peer identity needed for Olm', async () => {
  const relay = await startRelay();
  try {
    const { a, b, welcomeA, welcomeB, pair } = await connectBoth(relay);
    assert.equal(welcomeA.peerPresent, false);
    assert.equal(welcomeB.peerPresent, true);
    assert.ok(welcomeA.peer, 'A learns B public identity after B registers');
    assert.equal((welcomeA.peer as Record<string, string>).deviceId, pair.deviceB.deviceId);
    assert.equal((welcomeB.peer as Record<string, string>).deviceId, pair.deviceA.deviceId);

    const joined = await a.next('peer');
    assert.equal(joined.state, 'joined');
    assert.equal(joined.deviceId, pair.deviceB.deviceId);
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});

test('public Olm material is exchanged so the devices can start a ratchet', async () => {
  const relay = await startRelay();
  try {
    const pair = await registerPair(relay);
    const pairId = relay.server.store.pairId;
    const url = `ws://127.0.0.1:${relay.port}/v1/ws`;
    const helloA = helloWithOlm({ token: pair.tokenA, pairId, deviceId: pair.deviceA.deviceId, role: 'A' });
    const helloB = helloWithOlm({ token: pair.tokenB, pairId, deviceId: pair.deviceB.deviceId, role: 'B' });

    const a = await TestClient.connect(url, helloA, 'A');
    const welcomeA = await a.next('welcome');
    const b = await TestClient.connect(url, helloB, 'B');
    await b.next('welcome');

    const joined = await a.next('peer');
    const olmB = helloB.olm as { identityKey: string; oneTimeKey: string };
    assert.equal(joined.olmIdentityKey, olmB.identityKey);
    assert.equal(joined.olmOneTimeKey, olmB.oneTimeKey);

    const peerFromWelcome = welcomeA.peer as Record<string, string>;
    assert.equal(typeof peerFromWelcome.olmIdentityKey, 'string');
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});

test('ciphertext is relayed verbatim and the relay never returns plaintext', async () => {
  const relay = await startRelay();
  try {
    const { a, b } = await connectBoth(relay);
    const envelope = seal(SECRET, 'm_0001');
    a.send(msgFrame('m_0001', envelope));

    const relayed = await b.next('msg');
    assert.equal(relayed.from, 'A');
    assert.equal(relayed.seq, 1);
    const received = relayed.cipher as CipherEnvelope;
    assert.deepEqual(received, envelope, 'the relay must not alter the envelope');
    assert.equal(open(received), SECRET);

    // Nothing was echoed to the sender, and no server frame carried plaintext.
    await idle(100);
    assert.equal(a.received.some((frame) => frame.t === 'msg'), false);
    assert.equal(JSON.stringify(a.received).includes(SECRET), false);
    assert.equal(JSON.stringify(b.received).includes(SECRET), false);
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});

test('a modified message fails authentication at the receiver', async () => {
  const relay = await startRelay();
  try {
    const { a, b } = await connectBoth(relay);
    const envelope = seal(SECRET, 'm_0002');
    a.send(msgFrame('m_0002', tamper(envelope)));

    const relayed = await b.next('msg');
    assert.throws(() => open(relayed.cipher as CipherEnvelope), /invalid|tag|auth|corrupt/i);

    // The relay cannot detect this (it is end-to-end), which is exactly why the
    // receiver must authenticate; the UI surfaces a decryption failure.
    assert.notDeepEqual(relayed.cipher, envelope);
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});

test('replayed frame ids are rejected', async () => {
  const relay = await startRelay();
  try {
    const { a, b } = await connectBoth(relay);
    const envelope = seal(SECRET, 'm_0003');
    a.send(msgFrame('m_0003', envelope));
    await b.next('msg');

    a.send(msgFrame('m_0003', envelope));
    const err = await a.next('err');
    assert.equal(err.code, 'replay');

    await idle(100);
    assert.equal(b.received.filter((frame) => frame.t === 'msg').length, 1);
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});

test('nothing is queued while the peer is away, and nothing is replayed later', async () => {
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
    await a.next('welcome');

    const envelope = seal(SECRET, 'm_0004');
    a.send(msgFrame('m_0004', envelope));
    const err = await a.next('err');
    assert.equal(err.code, 'session_required');

    const b = await TestClient.connect(
      url,
      helloFrame({ token: pair.tokenB, pairId, deviceId: pair.deviceB.deviceId, role: 'B' }),
      'B',
    );
    await b.next('welcome');
    await a.next('peer');
    await idle(200);
    assert.equal(b.received.some((frame) => frame.t === 'msg'), false, 'no offline delivery exists');
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});

test('a signed hello cannot substitute the registered long-term Olm identity', async () => {
  const relay = await startRelay();
  try {
    const pair = await registerPair(relay);
    const pairId = relay.server.store.pairId;
    const url = `ws://127.0.0.1:${relay.port}/v1/ws`;
    const alteredHello = helloFrame({
      token: pair.tokenA,
      pairId,
      deviceId: pair.deviceA.deviceId,
      role: 'A',
      olmIdentityKey: b64u(randomBytes(32)),
    });
    const client = await TestClient.connect(url, alteredHello, 'olm-identity-substitution');
    const error = await client.next('err');
    assert.equal(error.code, 'unauthorized');
    assert.match(String(error.detail), /Olm identity key/);
    assert.equal((await client.waitClosed()).code, 4003);
  } finally {
    await relay.close();
  }
});

test('a bearer-token hello is refused: local mode requires a signature', async () => {
  const relay = await startRelay();
  try {
    const pair = await registerPair(relay);
    const url = `ws://127.0.0.1:${relay.port}/v1/ws`;
    // The real token, correct pair and device id: only the auth kind is wrong.
    const client = await TestClient.connect(
      url,
      {
        v: 1,
        t: 'hello',
        proto: 'sp1',
        pairId: relay.server.store.pairId,
        deviceId: pair.deviceA.deviceId,
        role: 'A',
        auth: { kind: 'token', token: pair.tokenA },
      },
      'token-hello',
    );
    const err = await client.next('err');
    assert.equal(err.code, 'unauthorized');
    assert.match(String(err.detail), /signed hello/);
    const closed = await client.waitClosed();
    assert.equal(closed.code, 4003);
  } finally {
    await relay.close();
  }
});

test('a third device cannot join, even with a valid-looking token', async () => {
  const relay = await startRelay();
  try {
    const pair = await registerPair(relay);
    const pairId = relay.server.store.pairId;
    const url = `ws://127.0.0.1:${relay.port}/v1/ws`;
    const intruder = await TestClient.connect(
      url,
      helloFrame({ token: pair.tokenA, pairId, deviceId: 'd_intruder', role: 'A' }),
      'intruder',
    );
    const err = await intruder.next('err');
    assert.equal(err.code, 'unauthorized');
    const closed = await intruder.waitClosed();
    assert.equal(closed.code, 4003);
  } finally {
    await relay.close();
  }
});

test('oversized frames are cut off at the transport, malformed ones are rejected in-band', async () => {
  const relay = await startRelay();
  try {
    const { a, b } = await connectBoth(relay);

    // A structurally invalid but small frame is answered and the session lives on.
    a.send({ v: 1, t: 'msg', id: 'm_bad', cipher: { senderKey: 'not base64!', body: 'x', kind: 1, msgId: 'm_bad', sentAt: 1 } });
    const err = await a.next('err');
    assert.equal(err.code, 'bad_frame');
    assert.equal(b.received.some((frame) => frame.t === 'msg'), false);

    a.send({ v: 1, t: 'ping', ts: Date.now() });
    const pong = await a.next('pong');
    assert.equal(typeof pong.serverTime, 'number');

    // Anything above the protocol cap is dropped by the WebSocket layer (1009),
    // which is the safe outcome: it is never parsed and never relayed.
    a.ws.send(JSON.stringify({ v: 1, t: 'msg', id: 'm_big', cipher: { body: 'A'.repeat(40_000) } }));
    const closed = await a.waitClosed();
    assert.equal(closed.code, 1009);
    assert.equal(b.received.some((frame) => frame.t === 'msg' && frame.id === 'm_big'), false);
    b.close();
  } finally {
    await relay.close();
  }
});

test('rate limiting stops a flood', async () => {
  const relay = await startRelay({ SECRETPLAY_RATE_PER_MINUTE: '30' });
  try {
    const { a, b } = await connectBoth(relay);
    for (let i = 0; i < 40; i += 1) {
      a.send(msgFrame(`m_flood_${i}`, seal(`flood ${i}`, `m_flood_${i}`)));
    }
    const err = await a.waitFor((frame) => frame.t === 'err' && frame.code === 'rate_limited');
    assert.equal(err.code, 'rate_limited');
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});
