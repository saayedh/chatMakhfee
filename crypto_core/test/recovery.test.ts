import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  RecoveryError,
  assertRecoveryPayloadSafe,
  newRecoveryId,
  openRecoveryPackage,
  sealRecoveryPackage,
  validateRecoveryPayload,
  type RecoveryPayload,
} from '../src/recovery.ts';
import { b64, b64Decode, randomBytes } from '../src/codec.ts';

// Deliberately tiny KDF parameters so the suite stays fast. Production uses RECOVERY_KDF.
const TEST_KDF = { name: 'argon2id' as const, m: 1024, t: 1, p: 1, dkLen: 32 as const };

function payload(overrides: Partial<RecoveryPayload> = {}): RecoveryPayload {
  return {
    pairId: 'pair-ABCD-EFGH-12',
    role: 'A',
    oldDeviceId: 'd_olddevice',
    oldIdentityPublicKey: b64(randomBytes(32)),
    peerDeviceId: 'd_peerdevice',
    peerPublicKey: b64(randomBytes(32)),
    createdAt: 1_700_000_000_000,
    recoveryId: newRecoveryId(),
    label: 'Phone A',
    ...overrides,
  };
}

test('sealing and opening a recovery package round-trips', () => {
  const original = payload();
  const sealed = sealRecoveryPackage({ secret: 'correct horse battery staple', payload: original, kdf: TEST_KDF });
  assert.equal(sealed.kind, 'sp1-recovery-sealed');
  const opened = openRecoveryPackage({ sealed, secret: 'correct horse battery staple' });
  assert.deepEqual(opened, original);
});

test('a wrong recovery secret fails closed without leaking the payload', () => {
  const sealed = sealRecoveryPackage({ secret: 'right-secret-123456', payload: payload(), kdf: TEST_KDF });
  assert.throws(
    () => openRecoveryPackage({ sealed, secret: 'wrong-secret-123456' }),
    (error: unknown) => error instanceof RecoveryError && error.code === 'bad_secret',
  );
});

test('tampered ciphertext is rejected', () => {
  const sealed = sealRecoveryPackage({ secret: 'a-long-enough-secret', payload: payload(), kdf: TEST_KDF });
  const bytes = b64Decode(sealed.ct);
  bytes[3] = (bytes[3] as number) ^ 0x01;
  assert.throws(
    () => openRecoveryPackage({ sealed: { ...sealed, ct: b64(bytes) }, secret: 'a-long-enough-secret' }),
    (error: unknown) => error instanceof RecoveryError && error.code === 'bad_secret',
  );
});

test('tampered aad is rejected', () => {
  const sealed = sealRecoveryPackage({ secret: 'a-long-enough-secret', payload: payload(), kdf: TEST_KDF });
  assert.throws(
    () => openRecoveryPackage({ sealed: { ...sealed, aad: 'secretplay.other.v1' }, secret: 'a-long-enough-secret' }),
    (error: unknown) => error instanceof RecoveryError,
  );
});

test('the expected aad context is enforced', () => {
  const sealed = sealRecoveryPackage({ secret: 'a-long-enough-secret', payload: payload(), kdf: TEST_KDF });
  assert.doesNotThrow(() => openRecoveryPackage({ sealed, secret: 'a-long-enough-secret', expectedAad: sealed.aad }));
  assert.throws(
    () => openRecoveryPackage({ sealed, secret: 'a-long-enough-secret', expectedAad: 'something.else' }),
    (error: unknown) => error instanceof RecoveryError && error.code === 'malformed',
  );
});

test('anything that looks like conversation data is refused before encryption', () => {
  const forbidden: Array<Record<string, unknown>> = [
    { ...payload(), messages: [] },
    { ...payload(), chatHistory: [] },
    { ...payload(), sessionKeys: ['k'] },
    { ...payload(), nested: { transcript: 'hello' } },
    { ...payload(), callRecordings: [] },
    { ...payload(), media: ['x'] },
  ];
  for (const candidate of forbidden) {
    assert.throws(
      () => sealRecoveryPackage({ secret: 'a-long-enough-secret', payload: candidate, kdf: TEST_KDF }),
      (error: unknown) => error instanceof RecoveryError && error.code === 'unsafe_payload',
      `expected refusal for ${Object.keys(candidate).join(',')}`,
    );
  }
});

test('payload validation enforces required identity fields', () => {
  const broken = [
    { ...payload(), pairId: 'x' },
    { ...payload(), role: 'C' },
    { ...payload(), oldDeviceId: '' },
    { ...payload(), oldIdentityPublicKey: 'not-base64!!' },
    { ...payload(), peerPublicKey: b64(randomBytes(16)) },
    { ...payload(), createdAt: 0 },
  ];
  for (const candidate of broken) {
    assert.throws(() => validateRecoveryPayload(candidate), (error: unknown) => error instanceof RecoveryError);
  }
});

test('unsafe-key detection walks arrays and nested objects', () => {
  assert.throws(() => assertRecoveryPayloadSafe({ a: [{ b: { plaintext: 'x' } }] }), /may not contain/);
  assert.doesNotThrow(() => assertRecoveryPayloadSafe({ a: [{ identityPublicKey: 'x' }] }));
});

test('malformed sealed packages are rejected before any KDF work', () => {
  const sealed = sealRecoveryPackage({ secret: 'a-long-enough-secret', payload: payload(), kdf: TEST_KDF });
  const cases: Array<[unknown, RegExp]> = [
    [null, /must be an object/],
    [{ ...sealed, v: 2 }, /version/],
    [{ ...sealed, kdf: { name: 'argon2id', m: 1 << 30, t: 1, p: 1, dkLen: 32 } }, /memory cost/],
    [{ ...sealed, kdf: { name: 'scrypt', m: 1024, t: 1, p: 1, dkLen: 32 } }, /argon2id/],
    [{ ...sealed, salt: b64(randomBytes(8)) }, /salt/],
    [{ ...sealed, nonce: b64(randomBytes(12)) }, /nonce/],
    [{ ...sealed, ct: '' }, /ciphertext/],
  ];
  for (const [candidate, pattern] of cases) {
    assert.throws(
      () => openRecoveryPackage({ sealed: candidate, secret: 'a-long-enough-secret' }),
      (error: unknown) => error instanceof RecoveryError && pattern.test(error.message),
    );
  }
});

test('short recovery secrets are refused', () => {
  assert.throws(
    () => sealRecoveryPackage({ secret: 'short', payload: payload(), kdf: TEST_KDF }),
    (error: unknown) => error instanceof RecoveryError && error.code === 'bad_secret',
  );
});
