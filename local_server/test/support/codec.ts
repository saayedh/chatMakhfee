/**
 * TEST STAND-IN CODEC — not the product's encryption.
 *
 * The Android client encrypts with vodozemac/Olm. That library is not available
 * in Node, so these relay tests use XChaCha20-Poly1305 (@noble/ciphers) with a
 * fixed test key to produce *opaque* envelopes with realistic properties:
 * authentication failure on tampering, and binding to the frame id + channel.
 *
 * The relay never sees the key and treats the result as opaque bytes, exactly
 * as it treats real Olm ciphertext. Nothing here ships in the app.
 */

import { xchacha20poly1305 } from '@noble/ciphers/chacha.js';
import { b64u, b64uDecode, randomBytes, sha256, utf8 } from '../../../crypto_core/src/index.ts';
import type { CipherEnvelope } from '../../../crypto_core/src/index.ts';

const TEST_KEY = sha256(utf8('secretplay.test.codec.v1'));

export type Channel = 'msg' | 'signal';

function aad(channel: Channel, msgId: string): Uint8Array {
  return utf8(`testcodec|${channel}|${msgId}`);
}

export function seal(plaintext: string, msgId: string, channel: Channel = 'msg'): CipherEnvelope {
  const nonce = randomBytes(24);
  const ciphertext = xchacha20poly1305(TEST_KEY, nonce, aad(channel, msgId)).encrypt(utf8(plaintext));
  const body = new Uint8Array(nonce.length + ciphertext.length);
  body.set(nonce, 0);
  body.set(ciphertext, nonce.length);
  return {
    senderKey: b64u(randomBytes(32)),
    kind: 1,
    body: b64u(body),
    msgId,
    sentAt: Date.now(),
  };
}

export function open(envelope: CipherEnvelope, channel: Channel = 'msg'): string {
  const body = b64uDecode(envelope.body);
  const nonce = body.subarray(0, 24);
  const ciphertext = body.subarray(24);
  return new TextDecoder().decode(
    xchacha20poly1305(TEST_KEY, nonce, aad(channel, envelope.msgId)).decrypt(ciphertext),
  );
}

export function tamper(envelope: CipherEnvelope): CipherEnvelope {
  const bytes = b64uDecode(envelope.body);
  bytes[bytes.length - 1] = (bytes[bytes.length - 1] as number) ^ 0xff;
  return { ...envelope, body: b64u(bytes) };
}
