import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  MAX_CIPHER_BODY_BYTES,
  MAX_FRAME_BYTES,
  encodeFrame,
  otherRole,
  parseClientFrame,
  roleForSlot,
  type CipherEnvelope,
} from '../src/frames.ts';
import { b64u, randomBytes } from '../src/codec.ts';

function cipher(overrides: Partial<CipherEnvelope> = {}): CipherEnvelope {
  return {
    senderKey: b64u(randomBytes(32)),
    kind: 1,
    body: b64u(randomBytes(64)),
    msgId: 'm_abc123',
    sentAt: 1_700_000_000_000,
    ...overrides,
  };
}

function hello(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    v: 1,
    t: 'hello',
    proto: 'sp1',
    pairId: 'pair-ABCD-EFGH-12',
    deviceId: 'd_abcdefghijklmnopqrstuv',
    role: 'A',
    auth: { kind: 'signed', ts: 1_700_000_000_000, nonce: b64u(randomBytes(16)), sig: b64u(randomBytes(64)) },
    olm: { identityKey: b64u(randomBytes(32)), oneTimeKey: b64u(randomBytes(32)) },
    ...overrides,
  });
}

test('accepts a well-formed signed hello', () => {
  const result = parseClientFrame(hello());
  assert.equal(result.ok, true);
  if (result.ok && result.frame.t === 'hello') {
    assert.equal(result.frame.role, 'A');
    assert.equal(result.frame.auth.kind, 'signed');
  }
});

test('accepts a token hello', () => {
  const result = parseClientFrame(hello({ auth: { kind: 'token', token: 'sp1t.payload.mac' } }));
  assert.equal(result.ok, true);
});

test('rejects malformed hellos', () => {
  const cases: Array<[string, RegExp]> = [
    [hello({ proto: 'sp2' }), /protocol id/],
    [hello({ pairId: '../etc/passwd' }), /pairId/],
    [hello({ role: 'C' }), /role/],
    [hello({ deviceId: '' }), /deviceId/],
    [hello({ auth: { kind: 'signed', ts: 1, nonce: 'x', sig: 'y' } }), /nonce|sig/],
    [hello({ olm: undefined }), /Olm/],
    [hello({ auth: { kind: 'password', token: 'x' } }), /auth.kind/],
    [hello({ v: 2 }), /version/],
  ];
  for (const [raw, pattern] of cases) {
    const result = parseClientFrame(raw);
    assert.equal(result.ok, false, `expected rejection for ${raw}`);
    if (!result.ok) assert.match(result.detail, pattern);
  }
});

test('accepts msg and signal frames as opaque envelopes', () => {
  for (const t of ['msg', 'signal'] as const) {
    const result = parseClientFrame(JSON.stringify({ v: 1, t, id: 'm_1', cipher: cipher() }));
    assert.equal(result.ok, true);
    if (result.ok) assert.equal(result.frame.t, t);
  }
});

test('rejects tampered or oversized cipher envelopes', () => {
  const oversized = new Uint8Array(MAX_CIPHER_BODY_BYTES + 1);
  oversized.set(randomBytes(4096), 0);
  const tooBig = cipher({ body: b64u(oversized) });
  assert.equal(parseClientFrame(JSON.stringify({ v: 1, t: 'msg', id: 'm_1', cipher: tooBig })).ok, false);

  const badKind = { ...cipher(), kind: 7 };
  assert.equal(parseClientFrame(JSON.stringify({ v: 1, t: 'msg', id: 'm_1', cipher: badKind })).ok, false);

  const missing = { ...cipher() } as Record<string, unknown>;
  delete missing.body;
  assert.equal(parseClientFrame(JSON.stringify({ v: 1, t: 'msg', id: 'm_1', cipher: missing })).ok, false);

  const badId = { ...cipher(), msgId: 'has spaces' };
  assert.equal(parseClientFrame(JSON.stringify({ v: 1, t: 'msg', id: 'm_1', cipher: badId })).ok, false);
});

test('rejects frames larger than the protocol limit', () => {
  const huge = JSON.stringify({ v: 1, t: 'msg', id: 'm_1', cipher: cipher(), pad: 'x'.repeat(MAX_FRAME_BYTES) });
  const result = parseClientFrame(huge);
  assert.equal(result.ok, false);
  if (!result.ok) assert.equal(result.detail, 'frame too large');
});

test('rejects non-JSON, unknown types, and non-objects', () => {
  assert.equal(parseClientFrame('not json').ok, false);
  assert.equal(parseClientFrame('[]').ok, false);
  assert.equal(parseClientFrame('{"v":1,"t":"dance"}').ok, false);
  assert.equal(parseClientFrame('').ok, false);
});

test('accepts ping and validated bye frames', () => {
  const ping = parseClientFrame(JSON.stringify({ v: 1, t: 'ping', ts: 1_700_000_000_000 }));
  assert.equal(ping.ok, true);

  const bye = parseClientFrame(JSON.stringify({ v: 1, t: 'bye', reason: 'lock' }));
  assert.equal(bye.ok, true);

  assert.equal(parseClientFrame(JSON.stringify({ v: 1, t: 'bye', reason: 'because' })).ok, false);
});

test('role helpers map slots to exactly two participants', () => {
  assert.equal(roleForSlot(1), 'A');
  assert.equal(roleForSlot(2), 'B');
  assert.equal(otherRole('A'), 'B');
  assert.equal(otherRole('B'), 'A');
});

test('encodeFrame produces parseable client frames', () => {
  const raw = encodeFrame({ v: 1, t: 'ping', ts: 1234 });
  const parsed = parseClientFrame(raw);
  assert.equal(parsed.ok, true);
  if (parsed.ok) assert.deepEqual(parsed.frame, { v: 1, t: 'ping', ts: 1234 });
});
