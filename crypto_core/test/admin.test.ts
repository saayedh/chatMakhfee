import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  MAX_ADMIN_SKEW_MS,
  signRevokeRequest,
  verifyRevokeRequest,
  type RevokeRequestInput,
} from '../src/admin.ts';
import { createDeviceIdentity, newHelloNonce } from '../src/auth.ts';
import type { Role } from '../src/frames.ts';

const PAIR = 'pair-ABCD-EFGH-12';

function request(overrides: Partial<RevokeRequestInput> = {}): RevokeRequestInput {
  return {
    pairId: PAIR,
    requesterRole: 'A' as Role,
    requesterDeviceId: 'd_requester',
    targetRole: 'B' as Role,
    ts: 1_700_000_000_000,
    nonce: newHelloNonce(),
    ...overrides,
  };
}

test('a signed revocation verifies for the requesting device only', () => {
  const identity = createDeviceIdentity();
  const input = request({ requesterDeviceId: identity.deviceId });
  const signed = signRevokeRequest(identity.secretKey, input);
  assert.deepEqual(
    verifyRevokeRequest({ pairId: PAIR, request: signed, publicKey: identity.publicKey, now: input.ts }),
    { ok: true },
  );

  const attacker = createDeviceIdentity();
  const result = verifyRevokeRequest({
    pairId: PAIR,
    request: signed,
    publicKey: attacker.publicKey,
    now: input.ts,
  });
  assert.equal(result.ok, false);
});

test('revocation is bound to the pair, roles and time', () => {
  const identity = createDeviceIdentity();
  const input = request({ requesterDeviceId: identity.deviceId });
  const signed = signRevokeRequest(identity.secretKey, input);

  assert.equal(
    verifyRevokeRequest({ pairId: 'pair-OTHER-0000-1', request: signed, publicKey: identity.publicKey, now: input.ts })
      .ok,
    false,
  );
  assert.equal(
    verifyRevokeRequest({
      pairId: PAIR,
      request: { ...signed, targetRole: 'A' },
      publicKey: identity.publicKey,
      now: input.ts,
    }).ok,
    false,
  );
  assert.equal(
    verifyRevokeRequest({
      pairId: PAIR,
      request: signed,
      publicKey: identity.publicKey,
      now: input.ts + MAX_ADMIN_SKEW_MS * 2,
    }).ok,
    false,
  );
});

test('self-revocation is refused even with a valid signature', () => {
  const identity = createDeviceIdentity();
  const input = request({ requesterDeviceId: identity.deviceId, requesterRole: 'A', targetRole: 'A' });
  const signed = signRevokeRequest(identity.secretKey, input);
  const result = verifyRevokeRequest({ pairId: PAIR, request: signed, publicKey: identity.publicKey, now: input.ts });
  assert.equal(result.ok, false);
  if (!result.ok) assert.match(result.detail, /own slot/);
});

test('a truncated signature is refused without throwing', () => {
  const identity = createDeviceIdentity();
  const input = request({ requesterDeviceId: identity.deviceId });
  const signed = signRevokeRequest(identity.secretKey, input);
  const result = verifyRevokeRequest({
    pairId: PAIR,
    request: { ...signed, sig: 'AAAA' },
    publicKey: identity.publicKey,
    now: input.ts,
  });
  assert.equal(result.ok, false);
});
