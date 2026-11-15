import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  helloFrame,
  idle,
  registerPair,
  signalFrame,
  startRelay,
  TestClient,
} from './support/relay.ts';
import { open, seal } from './support/codec.ts';
import type { CipherEnvelope } from '../../crypto_core/src/index.ts';

const OFFER = JSON.stringify({ type: 'offer', sdp: 'v=0\r\no=- 1 1 IN IP4 192.168.1.20\r\n...' });
const ANSWER = JSON.stringify({ type: 'answer', sdp: 'v=0\r\no=- 2 2 IN IP4 192.168.1.21\r\n...' });

async function connected(relay: Awaited<ReturnType<typeof startRelay>>) {
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
  return { a, b, pairId };
}

test('offer, answer and ICE candidates relay in both directions', async () => {
  const relay = await startRelay();
  try {
    const { a, b } = await connected(relay);

    a.send(signalFrame('s_offer', seal(OFFER, 's_offer', 'signal')));
    const offer = await b.next('signal');
    assert.equal(open(offer.cipher as CipherEnvelope, 'signal'), OFFER);
    assert.equal(offer.from, 'A');

    b.send(signalFrame('s_answer', seal(ANSWER, 's_answer', 'signal')));
    const answer = await a.next('signal');
    assert.equal(open(answer.cipher as CipherEnvelope, 'signal'), ANSWER);
    assert.equal(answer.from, 'B');

    const candidates = ['cand-1', 'cand-2', 'cand-3'].map((id) =>
      seal(JSON.stringify({ type: 'candidate', candidate: id }), id, 'signal'),
    );
    candidates.forEach((cipher, index) => {
      a.send(signalFrame(`s_ice_${index}`, cipher));
    });

    const received = [];
    for (let index = 0; index < candidates.length; index += 1) {
      received.push(await b.waitFor((frame) => frame.t === 'signal' && frame.id === `s_ice_${index}`));
    }
    const seqs = received.map((frame) => Number(frame.seq));
    assert.deepEqual([...seqs].sort((x, y) => x - y), seqs, 'signalling order is preserved');
    assert.equal(open(received[0]?.cipher as CipherEnvelope, 'signal'), JSON.stringify({ type: 'candidate', candidate: 'cand-1' }));

    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});

test('signal frames and message frames are separate channels', async () => {
  const relay = await startRelay();
  try {
    const { a, b } = await connected(relay);
    a.send(signalFrame('s_1', seal('rtc-payload', 's_1', 'signal')));
    a.send({ v: 1, t: 'msg', id: 'm_1', cipher: seal('chat-payload', 'm_1', 'msg') });

    const signal = await b.next('signal');
    const message = await b.next('msg');
    assert.equal(signal.t, 'signal');
    assert.equal(message.t, 'msg');
    assert.equal(open(signal.cipher as CipherEnvelope, 'signal'), 'rtc-payload');
    assert.equal(open(message.cipher as CipherEnvelope, 'msg'), 'chat-payload');

    // Signalling sealed for one channel must not open as the other.
    assert.throws(() => open(signal.cipher as CipherEnvelope, 'msg'), /invalid|tag|auth|corrupt/i);
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});

test('signalling cannot be relayed while the peer is absent', async () => {
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
    a.send(signalFrame('s_alone', seal(OFFER, 's_alone', 'signal')));
    const err = await a.next('err');
    assert.equal(err.code, 'session_required');
    await idle(100);
    assert.equal(relay.server.hub.activeSessionCount, 0);
  } finally {
    await relay.close();
  }
});

test('replayed signalling frames are rejected', async () => {
  const relay = await startRelay();
  try {
    const { a, b } = await connected(relay);
    a.send(signalFrame('s_replay', seal(OFFER, 's_replay', 'signal')));
    await b.next('signal');
    a.send(signalFrame('s_replay', seal(OFFER, 's_replay', 'signal')));
    const err = await a.next('err');
    assert.equal(err.code, 'replay');
    await idle(100);
    assert.equal(b.received.filter((frame) => frame.t === 'signal').length, 1);
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});
