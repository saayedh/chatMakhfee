import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  createInvite,
  hashInviteToken,
  INVITE_TTL_MS,
  isInviteExpired,
  isValidInviteToken,
  newPairId,
  pairingFingerprint,
} from '../src/pairing.ts';
import { b64u, randomBytes } from '../src/codec.ts';

test('invitations are unique, secret, and stored only as a hash', () => {
  const a = createInvite(1000);
  const b = createInvite(1000);
  assert.notEqual(a.token, b.token, 'invites must not repeat');
  assert.equal(a.token.length >= 30, true);
  assert.notEqual(a.hash, a.token, 'the stored value must not be the secret');
  assert.equal(a.hash, hashInviteToken(a.token));
  assert.equal(a.expiresAt, a.createdAt + INVITE_TTL_MS);
  assert.equal(isValidInviteToken(a.token), true);
  assert.equal(isValidInviteToken('short'), false);
  assert.equal(isValidInviteToken('!!!!'), false);
});

test('invitations expire', () => {
  const invite = createInvite(1000, 5000);
  assert.equal(isInviteExpired(invite, 4000), false);
  assert.equal(isInviteExpired(invite, 6000), true);
  assert.equal(isInviteExpired(invite, 6000), true);
});

test('different invites almost never share a hash', () => {
  const hashes = new Set<string>();
  for (let i = 0; i < 200; i += 1) hashes.add(createInvite().hash);
  assert.equal(hashes.size, 200);
});

test('pairing fingerprint is symmetric and formatted', () => {
  const a = randomBytes(32);
  const b = randomBytes(32);
  const forward = pairingFingerprint(a, b);
  const reverse = pairingFingerprint(b, a);
  assert.equal(forward, reverse, 'both devices must show the same code');
  assert.match(forward, /^\d{4} \d{4} \d{4}$/);
});

test('pairing fingerprint differs for different keys', () => {
  const a = randomBytes(32);
  const b = randomBytes(32);
  const c = randomBytes(32);
  assert.notEqual(pairingFingerprint(a, b), pairingFingerprint(a, c));
});

test('pair ids look like pair-XXXX-XXXX-XX and never contain confusables', () => {
  for (let i = 0; i < 50; i += 1) {
    const id = newPairId();
    assert.match(id, /^pair-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{2}$/);
    assert.equal(/[O0I1]/.test(id), false, 'avoid O/0 and I/1 in a code a human may read aloud');
  }
  assert.notEqual(newPairId(), newPairId());
});

test('invite hash binds the token bytes', () => {
  const token = b64u(randomBytes(24));
  assert.equal(hashInviteToken(token), hashInviteToken(token));
  assert.notEqual(hashInviteToken(token), hashInviteToken(b64u(randomBytes(24))));
});
