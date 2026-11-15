import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  b64u,
  b64uDecode,
  canonicalJson,
  fromUtf8,
  randomBytes,
  sha256Hex,
  timingSafeEqual,
  utf8,
  uuidv4,
} from '../src/codec.ts';

test('canonicalJson sorts keys and drops undefined', () => {
  const a = canonicalJson({ b: 1, a: { d: [3, 2, 1], c: 'x' } });
  const b = canonicalJson({ a: { c: 'x', d: [3, 2, 1] }, b: 1 });
  assert.equal(a, b);
  assert.equal(a, '{"a":{"c":"x","d":[3,2,1]},"b":1}');
  assert.equal(canonicalJson({ a: 1, ignored: undefined }), '{"a":1}');
});

test('canonicalJson refuses non-finite numbers', () => {
  assert.throws(() => canonicalJson({ a: Number.NaN }), /non-finite/);
  assert.throws(() => canonicalJson({ a: Number.POSITIVE_INFINITY }), /non-finite/);
});

test('base64url round-trips arbitrary bytes and is url-safe', () => {
  for (const length of [1, 2, 15, 16, 31, 32, 100, 1024]) {
    const bytes = randomBytes(length);
    const encoded = b64u(bytes);
    assert.match(encoded, /^[A-Za-z0-9_-]+$/);
    assert.deepEqual(b64uDecode(encoded), bytes);
  }
});

test('base64url rejects invalid input', () => {
  assert.throws(() => b64uDecode('not base64!'), /url-safe/);
  assert.throws(() => b64uDecode('a+b/c'), /url-safe/);
});

test('utf8 round-trip preserves non-ASCII text', () => {
  const text = 'سلام — ☕️ rocket 🚀';
  assert.equal(fromUtf8(utf8(text)), text);
});

test('sha256Hex is stable', () => {
  assert.equal(sha256Hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

test('timingSafeEqual compares content, not identity', () => {
  const a = randomBytes(32);
  const b = new Uint8Array(a);
  assert.equal(timingSafeEqual(a, b), true);
  b[0] = (b[0] as number) ^ 0xff;
  assert.equal(timingSafeEqual(a, b), false);
  assert.equal(timingSafeEqual(a, a.subarray(0, 16)), false);
});

test('randomBytes rejects silly lengths', () => {
  assert.throws(() => randomBytes(0), /length/);
  assert.throws(() => randomBytes(5000), /length/);
});

test('uuidv4 has the right shape and version nibble', () => {
  const id = uuidv4();
  assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.notEqual(uuidv4(), id);
});
