import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ed25519 } from '@noble/curves/ed25519.js';

import {
  ReplayGuard,
  createDeviceIdentity,
  deviceIdFromPublicKey,
  issueSessionToken,
  newHelloNonce,
  signHello,
  verifySessionToken,
  verifySignedHello,
} from '../src/auth.ts';
import { b64u, randomBytes, utf8 } from '../src/codec.ts';

const PAIR = 'pair-ABCD-EFGH-12';

function signedHello(identity = createDeviceIdentity(), role: 'A' | 'B' = 'A', now = Date.now()) {
  const input = {
    pairId: PAIR,
    deviceId: identity.deviceId,
    role,
    ts: now,
    nonce: newHelloNonce(),
    olm: { identityKey: b64u(randomBytes(32)), oneTimeKey: b64u(randomBytes(32)) },
  };
  return {
    identity,
    role,
    auth: { ts: input.ts, nonce: input.nonce, sig: signHello(identity.secretKey, input) },
    olm: input.olm,
  };
}

test('device identity derives a stable device id from the public key', () => {
  const identity = createDeviceIdentity();
  assert.equal(identity.publicKey.length, 32);
  assert.equal(identity.deviceId, deviceIdFromPublicKey(identity.publicKey));
  assert.notEqual(createDeviceIdentity().deviceId, identity.deviceId);
});

test('a correctly signed hello verifies with its Olm bootstrap material', () => {
  const { identity, auth, role, olm } = signedHello();
  const result = verifySignedHello({
    publicKey: identity.publicKey,
    pairId: PAIR,
    deviceId: identity.deviceId,
    role,
    auth,
    olm,
    now: auth.ts,
  });
  assert.deepEqual(result, { ok: true });
});

test('a signed hello rejects altered Olm bootstrap keys', () => {
  const { identity, auth, role, olm } = signedHello();
  const altered = { ...olm, oneTimeKey: b64u(randomBytes(32)) };
  const result = verifySignedHello({
    publicKey: identity.publicKey,
    pairId: PAIR,
    deviceId: identity.deviceId,
    role,
    auth,
    olm: altered,
    now: auth.ts,
  });
  assert.equal(result.ok, false);
});

test('a hello signed by the wrong device is rejected', () => {
  const { auth, role, olm } = signedHello();
  const attacker = createDeviceIdentity();
  const result = verifySignedHello({
    publicKey: attacker.publicKey,
    pairId: PAIR,
    deviceId: attacker.deviceId,
    role,
    auth,
    olm,
    now: auth.ts,
  });
  assert.equal(result.ok, false);
});

test('a hello with a mismatched deviceId is rejected before signature checks', () => {
  const { identity, auth, role, olm } = signedHello();
  const result = verifySignedHello({
    publicKey: identity.publicKey,
    pairId: PAIR,
    deviceId: 'd_someone_else',
    role,
    auth,
    olm,
    now: auth.ts,
  });
  assert.equal(result.ok, false);
  if (!result.ok) assert.match(result.detail, /deviceId/);
});

test('a hello replayed into a different role is rejected', () => {
  const { identity, auth, olm } = signedHello(undefined, 'A');
  const result = verifySignedHello({
    publicKey: identity.publicKey,
    pairId: PAIR,
    deviceId: identity.deviceId,
    role: 'B',
    auth,
    olm,
    now: auth.ts,
  });
  assert.equal(result.ok, false);
});

test('a hello replayed into a different pair is rejected', () => {
  const { identity, auth, role, olm } = signedHello();
  const result = verifySignedHello({
    publicKey: identity.publicKey,
    pairId: 'pair-ZZZZ-ZZZZ-99',
    deviceId: identity.deviceId,
    role,
    auth,
    olm,
    now: auth.ts,
  });
  assert.equal(result.ok, false);
});

test('an old hello outside the skew window is rejected', () => {
  const now = Date.now();
  const { identity, auth, role, olm } = signedHello(undefined, 'A', now - 10 * 60 * 1000);
  const result = verifySignedHello({
    publicKey: identity.publicKey,
    pairId: PAIR,
    deviceId: identity.deviceId,
    role,
    auth,
    olm,
    now,
  });
  assert.equal(result.ok, false);
  if (!result.ok) assert.match(result.detail, /window/);
});

test('a hello with a garbage signature is rejected without throwing', () => {
  const { identity, auth, role, olm } = signedHello();
  const result = verifySignedHello({
    publicKey: identity.publicKey,
    pairId: PAIR,
    deviceId: identity.deviceId,
    role,
    auth: { ...auth, sig: b64u(new Uint8Array(64)) },
    olm,
    now: auth.ts,
  });
  assert.equal(result.ok, false);
});

test('signatures over different bytes do not verify', () => {
  const identity = createDeviceIdentity();
  const sig = ed25519.sign(utf8('payload-a'), identity.secretKey);
  assert.equal(ed25519.verify(sig, utf8('payload-b'), identity.publicKey), false);
});

test('ReplayGuard accepts a nonce exactly once, then expires it', () => {
  const guard = new ReplayGuard({ ttlMs: 1000 });
  const now = 1_000_000;
  assert.equal(guard.check('nonce-1', now), true);
  assert.equal(guard.check('nonce-1', now + 1), false);
  assert.equal(guard.check('nonce-1', now + 2000), true, 'expired entries are re-accepted by design');
});

test('ReplayGuard stays bounded', () => {
  const guard = new ReplayGuard({ ttlMs: 60_000, maxEntries: 10 });
  for (let i = 0; i < 100; i += 1) guard.check(`n-${i}`, 1000 + i);
  assert.ok(guard.size <= 10, `expected <= 10 entries, got ${guard.size}`);
});

test('session tokens round-trip with claims', () => {
  const secret = randomBytes(32);
  const now = 1_700_000_000_000;
  const { token, claims } = issueSessionToken({
    secret,
    pairId: PAIR,
    deviceId: 'd_device_one',
    role: 'B',
    ttlMs: 60_000,
    now,
  });
  const verified = verifySessionToken({ secret, token, pairId: PAIR, deviceId: 'd_device_one', role: 'B', now });
  assert.equal(verified.ok, true);
  if (verified.ok) assert.equal(verified.claims.exp, claims.exp);
});

test('tampered session tokens are rejected', () => {
  const secret = randomBytes(32);
  const { token } = issueSessionToken({ secret, pairId: PAIR, deviceId: 'd_x', role: 'A' });
  const parts = token.split('.');
  const flipped = `${parts[0]}.${parts[1]}.${b64u(randomBytes(32))}`;
  const result = verifySessionToken({ secret, token: flipped });
  assert.equal(result.ok, false);
  if (!result.ok) assert.match(result.detail, /MAC/);
});

test('session tokens are bound to pair, device and role', () => {
  const secret = randomBytes(32);
  const { token } = issueSessionToken({ secret, pairId: PAIR, deviceId: 'd_x', role: 'A' });
  assert.equal(verifySessionToken({ secret, token, pairId: 'pair-OTHER-0000-1' }).ok, false);
  assert.equal(verifySessionToken({ secret, token, deviceId: 'd_y' }).ok, false);
  assert.equal(verifySessionToken({ secret, token, role: 'B' }).ok, false);
});

test('expired and foreign-key session tokens are rejected', () => {
  const secret = randomBytes(32);
  const now = 1_700_000_000_000;
  const { token } = issueSessionToken({ secret, pairId: PAIR, deviceId: 'd_x', role: 'A', ttlMs: 1000, now });
  const expired = verifySessionToken({ secret, token, now: now + 2000 });
  assert.equal(expired.ok, false);
  if (!expired.ok) assert.match(expired.detail, /expired/);

  const foreign = verifySessionToken({ secret: randomBytes(32), token });
  assert.equal(foreign.ok, false);
});

test('malformed session tokens are rejected', () => {
  const secret = randomBytes(32);
  for (const token of ['', 'sp1t', 'a.b.c', 'sp1t.!!!.!!!', 'xx.y.z']) {
    assert.equal(verifySessionToken({ secret, token }).ok, false, `expected rejection of "${token}"`);
  }
});
