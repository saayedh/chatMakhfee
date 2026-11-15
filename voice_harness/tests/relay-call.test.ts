/**
 * LAN-mode signalling through the real sp1 relay.
 *
 * The two peers are genuine WebRTC endpoints; the offer/answer/ICE payloads they
 * exchange are the ones the app puts inside Olm envelopes. Here they are wrapped
 * in the same envelope shape with a stand-in body (the relay is ciphertext-blind,
 * so this tests the transport rules and the SDP size budget, not app crypto).
 *
 * Also covers call teardown: ending the session through the relay must close both
 * sockets with 4000 and stop the media path.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  helloFrame,
  registerPair,
  startRelay,
  TestClient,
  type TestRelay,
} from '../../local_server/test/support/relay.ts';
import {
  MAX_CIPHER_BODY_BYTES,
  parseClientFrame,
  type CipherEnvelope,
} from '../../crypto_core/src/index.ts';
import {
  attachAudio,
  createAudioPeer,
  receiveAudio,
  selectedPair,
  sendAudio,
  waitForState,
} from './support/rtc.ts';

const enc = (text: string): string => Buffer.from(text, 'utf8').toString('base64url');
const dec = (body: string): string => Buffer.from(body, 'base64').toString('utf8');

function envelope(id: string, text: string): CipherEnvelope {
  return {
    senderKey: Buffer.alloc(32, 7).toString('base64url'),
    kind: 1,
    body: enc(text),
    msgId: id,
    sentAt: Date.now(),
  };
}

async function relayPair(relay: TestRelay) {
  const pair = await registerPair(relay);
  const pairId = relay.server.store.pairId;
  const url = `ws://127.0.0.1:${relay.port}/v1/ws`;
  const a = await TestClient.connect(
    url,
    helloFrame({ pairId, deviceId: pair.deviceA.deviceId, role: 'A' }),
    'A',
  );
  const b = await TestClient.connect(
    url,
    helloFrame({ pairId, deviceId: pair.deviceB.deviceId, role: 'B' }),
    'B',
  );
  await a.next('welcome');
  await b.next('welcome');
  await a.next('peer');
  return { a, b };
}

test('a real audio call is negotiated through the sp1 signal frames', async () => {
  const relay = await startRelay();
  const peerA = createAudioPeer({ iceServers: [] });
  const peerB = createAudioPeer({ iceServers: [] });
  const tracks = [];
  tracks.push(attachAudio(peerA), attachAudio(peerB));

  const candidatesForB: string[] = [];
  const candidatesForA: string[] = [];
  peerA.onIceCandidate.subscribe((c) => {
    if (c.candidate) candidatesForB.push(c.candidate);
  });
  peerB.onIceCandidate.subscribe((c) => {
    if (c.candidate) candidatesForA.push(c.candidate);
  });

  try {
    const { a, b } = await relayPair(relay);

    // --- offer: real SDP, measured against the relay's envelope budget ----
    const offer = await peerA.createOffer();
    await peerA.setLocalDescription(offer);
    const offerJson = JSON.stringify({ type: 'offer', sdp: offer.sdp });
    const offerEnvelope = envelope('s_offer', offerJson);
    const wireFrame = JSON.stringify({ v: 1, t: 'signal', id: 's_offer', cipher: offerEnvelope });

    assert.ok(
      Buffer.byteLength(offerJson) < MAX_CIPHER_BODY_BYTES,
      `offer SDP JSON is ${Buffer.byteLength(offerJson)} bytes, envelope cap is ${MAX_CIPHER_BODY_BYTES}`,
    );
    const parsed = parseClientFrame(wireFrame);
    assert.equal(parsed.ok, true, `relay parser rejects a real offer frame: ${JSON.stringify(parsed)}`);

    a.send({ v: 1, t: 'signal', id: 's_offer', cipher: offerEnvelope });
    const offerFrame = await b.next('signal');
    assert.equal(offerFrame.from, 'A');
    const receivedOffer = JSON.parse(dec((offerFrame.cipher as CipherEnvelope).body));
    assert.equal(receivedOffer.type, 'offer');
    await peerB.setRemoteDescription({ type: 'offer', sdp: receivedOffer.sdp });

    // --- answer ----------------------------------------------------------
    const answer = await peerB.createAnswer();
    await peerB.setLocalDescription(answer);
    const answerJson = JSON.stringify({ type: 'answer', sdp: answer.sdp });
    b.send({ v: 1, t: 'signal', id: 's_answer', cipher: envelope('s_answer', answerJson) });
    const answerFrame = await a.next('signal');
    const receivedAnswer = JSON.parse(dec((answerFrame.cipher as CipherEnvelope).body));
    await peerA.setRemoteDescription({ type: 'answer', sdp: receivedAnswer.sdp });

    // --- trickle ICE both ways ------------------------------------------
    const trickle = async (sender: TestClient, strings: string[], toPeer: typeof peerA, tag: string, receiver: TestClient) => {
      for (const [index, candidate] of strings.entries()) {
        const id = `${tag}_${index}`;
        sender.send({
          v: 1,
          t: 'signal',
          id,
          cipher: envelope(id, JSON.stringify({ type: 'ice', candidate, sdpMid: '0', sdpMLineIndex: 0 })),
        });
        const frame = await receiver.waitFor((f) => f.t === 'signal' && f.id === id);
        const payload = JSON.parse(dec((frame.cipher as CipherEnvelope).body));
        await toPeer.addIceCandidate({
          candidate: payload.candidate,
          sdpMid: payload.sdpMid,
          sdpMLineIndex: payload.sdpMLineIndex,
        });
      }
    };

    // Let both sides gather before relaying so the loop can be deterministic.
    await new Promise((resolve) => setTimeout(resolve, 700));
    await trickle(a, candidatesForB, peerB, 's_ice_a', b);
    await trickle(b, candidatesForA, peerA, 's_ice_b', a);

    await waitForState(peerA, 'connected', 15_000);
    await waitForState(peerB, 'connected', 15_000);

    const pairA = selectedPair(peerA);
    assert.ok(pairA, 'a candidate pair was selected');
    assert.match(pairA.local.candidate, / typ host /);
    assert.equal(peerA.dtlsTransports[0]?.state, 'connected');
    assert.equal(peerA.dtlsTransports[0]?.srtpStarted, true);
    assert.equal(peerB.dtlsTransports[0]?.srtpStarted, true);

    const aRx = receiveAudio(peerA, 'A');
    const bRx = receiveAudio(peerB, 'B');
    const aReady = aRx.attach();
    const bReady = bRx.attach();
    await sendAudio(peerA, 5, 5);
    await sendAudio(peerB, 5, 6);
    await Promise.all([aReady, bReady]);
    assert.ok(bRx.packets.length >= 3, 'B heard A through the relay-negotiated call');
    assert.ok(aRx.packets.length >= 3, 'A heard B through the relay-negotiated call');

    // --- teardown: bye ends the session and both sockets close 4000 ------
    a.send({ v: 1, t: 'bye', reason: 'lock' });
    const end = await b.next('end');
    assert.equal(end.reason, 'peer_locked');
    const closedB = await b.waitClosed();
    assert.equal(closedB.code, 4000);

    await peerA.close();
    await peerB.close();
    assert.equal(peerA.connectionState, 'closed');
    assert.equal(peerB.connectionState, 'closed');
  } finally {
    for (const track of tracks) await track.stop().catch(() => {});
    await peerA.close().catch(() => {});
    await peerB.close().catch(() => {});
    await relay.close();
  }
});

test('an SDP larger than the envelope cap is rejected by the relay, not silently truncated', () => {
  // Padding stands in for a pathological SDP (many candidates/extensions).
  const oversized = JSON.stringify({ type: 'offer', sdp: 'v=0\r\n' + 'a=x\r\n'.repeat(2000) });
  const frame = JSON.stringify({ v: 1, t: 'signal', id: 's_big', cipher: envelope('s_big', oversized) });
  const parsed = parseClientFrame(frame);
  assert.equal(parsed.ok, false);
  if (!parsed.ok) assert.equal(parsed.code, 'bad_frame');
});
