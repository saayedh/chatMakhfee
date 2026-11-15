/**
 * LAN / offline mode: no STUN, no TURN, host candidates only.
 *
 * Asserts, from live peers:
 *  - ICE gathering completes without any external server (offline capable);
 *  - every local candidate is a host candidate;
 *  - the selected pair is host <-> host;
 *  - DTLS completes and SRTP keys are installed;
 *  - the SDP is an audio m-line with an sha-256 fingerprint and opus;
 *  - Opus RTP flows in both directions.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  answerFrom,
  candidateType,
  collectCandidates,
  makePair,
  offerFrom,
  receiveAudio,
  selectedPair,
  sendAudio,
  waitForState,
} from './support/rtc.ts';

test('LAN mode: host-only ICE, DTLS-SRTP, bidirectional Opus audio', async () => {
  const pair = await makePair({ iceServers: [] });
  try {
    const aGather = collectCandidates(pair.a);
    const bGather = collectCandidates(pair.b);
    const aRx = receiveAudio(pair.a, 'A');
    const bRx = receiveAudio(pair.b, 'B');

    const offer = await offerFrom(pair.a);
    const answer = await answerFrom(pair.b, offer);
    await pair.a.setRemoteDescription(answer);
    await pair.pump();

    await Promise.all([aGather.done, bGather.done]);
    await pair.pump();
    await waitForState(pair.a, 'connected');
    await waitForState(pair.b, 'connected');

    // 1. Offline capability: nothing but host candidates was gathered.
    assert.ok(aGather.list.length >= 1, 'A gathered at least one candidate');
    for (const candidate of [...aGather.list, ...bGather.list]) {
      assert.equal(
        candidateType(candidate),
        'host',
        `LAN mode must not gather non-host candidates, saw: ${candidate}`,
      );
    }

    // 2. Connectivity is a direct host-to-host path.
    const pairA = selectedPair(pair.a);
    assert.ok(pairA, 'A has a selected candidate pair');
    assert.match(pairA.local.candidate, / typ host /);
    assert.match(pairA.remote.candidate, / typ host /);

    // 3. DTLS-SRTP is active in both directions.
    for (const [label, pc] of [
      ['A', pair.a],
      ['B', pair.b],
    ] as const) {
      const transport = pc.dtlsTransports[0];
      assert.ok(transport, `${label} has a DTLS transport`);
      assert.equal(transport.state, 'connected', `${label} DTLS connected`);
      assert.equal(transport.srtpStarted, true, `${label} SRTP keys installed`);
    }

    // 4. The negotiated media is encrypted audio.
    const sdp = pair.a.localDescription?.sdp ?? '';
    assert.match(sdp, /m=audio \d+ UDP\/TLS\/RTP\/SAVPF \d+/, 'audio m-line is SAVPF (SRTP)');
    assert.match(sdp, /a=fingerprint:sha-256 /, 'DTLS certificate fingerprint is offered');
    assert.match(sdp, /a=rtpmap:111 opus\/48000\/2/, 'opus is negotiated');

    // 5. Real RTP crosses the SRTP path both ways.
    const aReady = aRx.attach();
    const bReady = bRx.attach();
    await sendAudio(pair.a, 5, 1);
    await sendAudio(pair.b, 5, 2);
    await Promise.all([aReady, bReady]);
    assert.ok(bRx.packets.length >= 3, `B received audio (${bRx.packets.length} packets)`);
    assert.ok(aRx.packets.length >= 3, `A received audio (${aRx.packets.length} packets)`);
    assert.ok(
      bRx.packets.every((packet) => packet.bytes > 0),
      'received RTP carried a non-empty Opus payload',
    );
  } finally {
    await pair.close();
  }
});

test('LAN mode: a peer that goes away is detected and the call can be torn down', async () => {
  const pair = await makePair({ iceServers: [] });
  try {
    const offer = await offerFrom(pair.a);
    const answer = await answerFrom(pair.b, offer);
    await pair.a.setRemoteDescription(answer);
    await pair.pump();
    await waitForState(pair.a, 'connected');

    // Deterministic local teardown, as the app does on hangup or lock.
    await pair.b.close();
    const closedDeadline = Date.now() + 3000;
    while (Date.now() < closedDeadline && pair.b.connectionState !== 'closed') {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.equal(pair.b.connectionState, 'closed', 'B is closed immediately on teardown');

    // The surviving peer must stop treating the call as connected. ICE consent
    // failure can take up to ~30 s, so this is bounded generously.
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline && pair.a.connectionState === 'connected') {
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    assert.notEqual(pair.a.connectionState, 'connected', 'A notices B is gone');
  } finally {
    await pair.close();
  }
});
