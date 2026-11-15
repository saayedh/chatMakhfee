import { test } from 'node:test';
import assert from 'node:assert/strict';

import { PairStore } from '../src/store.ts';
import { isInviteExpired } from '../../crypto_core/src/index.ts';
import {
  TEST_ADMIN_TOKEN,
  helloFrame,
  localRegistrationBody,
  makeDevice,
  register,
  registerPair,
  startRelay,
  TestClient,
} from './support/relay.ts';

test('pairs exactly two devices and refuses a third', async () => {
  const relay = await startRelay();
  try {
    const a = await registerPair(relay);
    assert.equal(a.roleA, 'A');
    assert.equal(a.roleB, 'B');
    assert.deepEqual(relay.server.store.slotsFilled, 2);
    assert.equal(relay.server.store.isComplete, true);

    const third = makeDevice();
    const attempt = await register(relay, 'a'.repeat(32), third);
    assert.equal(attempt.status, 409);
    assert.equal(attempt.body.error, 'pair_full');
    assert.equal(relay.server.store.deviceByDeviceId(third.deviceId), null);
  } finally {
    await relay.close();
  }
});

test('a one-time invitation cannot be reused', async () => {
  const relay = await startRelay();
  try {
    const invite = relay.server.currentInvite();
    assert.ok(invite);
    const first = await register(relay, invite.token, makeDevice());
    assert.equal(first.status, 200);

    const second = await register(relay, invite.token, makeDevice());
    assert.equal(second.status, 403);
    assert.equal(second.body.error, 'unauthorized');
  } finally {
    await relay.close();
  }
});

test('an unknown or malformed invitation is rejected', async () => {
  const relay = await startRelay();
  try {
    assert.equal((await register(relay, 'not-a-real-invite-value', makeDevice())).status, 403);
    assert.equal(relay.server.store.slotsFilled, 0);
  } finally {
    await relay.close();
  }
});

test('device id must be derived from the supplied public key', async () => {
  const relay = await startRelay();
  try {
    const invite = relay.server.currentInvite();
    assert.ok(invite);
    const victim = makeDevice();
    const challengeResponse = await fetch(
      `${relay.base}/v1/pair/challenge?pairId=${encodeURIComponent(relay.server.store.pairId)}`,
    );
    const challenge = (await challengeResponse.json()) as Record<string, unknown>;
    const body = localRegistrationBody(
      relay,
      invite.token,
      challenge.challenge as string,
      victim,
      'd_attacker_chosen_id',
    );
    const response = await fetch(`${relay.base}/v1/pair/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    assert.equal(response.status, 403);
    assert.equal(relay.server.store.slotsFilled, 0);
  } finally {
    await relay.close();
  }
});


test('local registration consumes a challenge exactly once', async () => {
  const relay = await startRelay();
  try {
    const invite = relay.server.currentInvite();
    assert.ok(invite);
    const device = makeDevice();
    const challengeResponse = await fetch(
      `${relay.base}/v1/pair/challenge?pairId=${encodeURIComponent(relay.server.store.pairId)}`,
    );
    assert.equal(challengeResponse.status, 200);
    const challengeBody = (await challengeResponse.json()) as Record<string, unknown>;
    const challenge = challengeBody.challenge;
    assert.equal(typeof challenge, 'string');
    const body = localRegistrationBody(relay, invite.token, challenge as string, device);
    assert.equal('invite' in body, false, 'the raw QR invitation must not be sent in the registration body');

    const send = () => fetch(`${relay.base}/v1/pair/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    const first = await send();
    assert.equal(first.status, 200);
    const replay = await send();
    assert.equal(replay.status, 403);
    assert.equal(relay.server.store.slotsFilled, 1);
  } finally {
    await relay.close();
  }
});

test('invalid proof consumes its challenge and cannot be retried', async () => {
  const relay = await startRelay();
  try {
    const challengeResponse = await fetch(
      `${relay.base}/v1/pair/challenge?pairId=${encodeURIComponent(relay.server.store.pairId)}`,
    );
    const challengeBody = (await challengeResponse.json()) as Record<string, unknown>;
    const challenge = challengeBody.challenge;
    const device = makeDevice();
    const body = localRegistrationBody(relay, 'wrong-invitation', challenge as string, device);
    const send = () => fetch(`${relay.base}/v1/pair/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    assert.equal((await send()).status, 403);
    assert.equal((await send()).status, 403);
    assert.equal(relay.server.store.slotsFilled, 0);
  } finally {
    await relay.close();
  }
});

test('a wrong public key length is rejected by the store', async () => {
  const store = new PairStore();
  const invite = store.ensureInvite();
  assert.ok(invite);
  const result = store.register({
    inviteToken: invite.token,
    deviceId: 'd_whatever',
    publicKey: new Uint8Array(16),
  });
  assert.equal(result.ok, false);
  if (!result.ok) assert.equal(result.code, 'unauthorized');
});

test('invitations expire and are then unusable', () => {
  let clock = 1_000_000;
  const store = new PairStore({ now: () => clock, inviteTtlMs: 5_000 });
  const invite = store.ensureInvite();
  assert.ok(invite);
  clock += 6_000;
  assert.equal(isInviteExpired(invite, clock), true);

  const device = makeDevice();
  const result = store.register({ inviteToken: invite.token, deviceId: device.deviceId, publicKey: device.publicKey });
  assert.equal(result.ok, false);
  if (!result.ok) assert.equal(result.code, 'unauthorized');
});

test('revocation frees a slot, kills the session and issues a fresh invitation', async () => {
  const relay = await startRelay();
  try {
    const pair = await registerPair(relay);
    const a = await TestClient.connect(
      relay.server.wsUrl().replace('ws://' + new URL(relay.server.wsUrl()).hostname, 'ws://127.0.0.1'),
      helloFrame({
        token: pair.tokenA,
        pairId: relay.server.store.pairId,
        deviceId: pair.deviceA.deviceId,
        role: 'A',
      }),
      'A',
    );
    const b = await TestClient.connect(
      relay.server.wsUrl().replace('ws://' + new URL(relay.server.wsUrl()).hostname, 'ws://127.0.0.1'),
      helloFrame({
        token: pair.tokenB,
        pairId: relay.server.store.pairId,
        deviceId: pair.deviceB.deviceId,
        role: 'B',
      }),
      'B',
    );
    await a.next('welcome');
    await b.next('welcome');

    const response = await fetch(`${relay.base}/v1/admin/revoke`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-admin-token': TEST_ADMIN_TOKEN },
      body: JSON.stringify({ role: 'A' }),
    });
    assert.equal(response.status, 200);
    const end = await b.next('end');
    assert.equal(end.reason, 'revoked');
    assert.equal(relay.server.store.slotsFilled, 1);
    assert.ok(relay.server.currentInvite(), 'a fresh invitation allows re-pairing the empty slot');

    // The revoked device can no longer authenticate.
    const rejected = await TestClient.connect(
      relay.base.replace('http://', 'ws://') + '/v1/ws',
      helloFrame({
        token: pair.tokenA,
        pairId: relay.server.store.pairId,
        deviceId: pair.deviceA.deviceId,
        role: 'A',
      }),
      'revoked-A',
    );
    const err = await rejected.next('err');
    assert.equal(err.code, 'device_revoked');
    a.close();
    b.close();
  } finally {
    await relay.close();
  }
});

test('health output never leaks invitations or tokens', async () => {
  const relay = await startRelay();
  try {
    await registerPair(relay);
    const response = await fetch(`${relay.base}/health`);
    const text = await response.text();
    const invite = relay.server.currentInvite();
    assert.equal(text.includes('token'), false);
    assert.equal(text.includes('invite='), false);
    if (invite) assert.equal(text.includes(invite.token), false);
    const body = JSON.parse(text) as Record<string, unknown>;
    assert.equal(body.status, 'ok');
    assert.equal(body.mode, 'local');
  } finally {
    await relay.close();
  }
});

test('admin endpoints require the console token', async () => {
  const relay = await startRelay();
  try {
    for (const path of ['/v1/admin/invite', '/v1/admin/reset', '/v1/admin/shutdown', '/v1/admin/revoke']) {
      const response = await fetch(`${relay.base}${path}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ role: 'A' }),
      });
      assert.equal(response.status, 401, `${path} must reject a missing admin token`);
    }
  } finally {
    await relay.close();
  }
});
