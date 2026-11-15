/**
 * Encrypted recovery package: Argon2id (RFC 9106) + XChaCha20-Poly1305.
 *
 * What a package contains (and nothing else):
 *   - the pair id and the slot the recovering device used to occupy
 *   - the old device's *public* identity key (for comparison on the peer)
 *   - the peer device id + public key (so the peer can confirm the request)
 *   - a creation timestamp and an opaque recovery id
 *   - a human label chosen by the user
 *
 * What it must never contain: messages, transcripts, session keys, ratchet
 * state, call recordings, media, or any plaintext conversation data. The
 * validator below rejects those keys defensively, so a bug elsewhere cannot
 * silently smuggle conversation data into a backup.
 *
 * A recovered device always generates a *new* identity and must be approved by
 * the surviving peer via the SAS flow. Possession of a recovery package is
 * never sufficient on its own to be trusted.
 */

import { argon2id } from '@noble/hashes/argon2.js';
import { xchacha20poly1305 } from '@noble/ciphers/chacha.js';
import {
  b64,
  b64Decode,
  b64u,
  canonicalJson,
  fromUtf8,
  isRecord,
  randomBytes,
  utf8,
} from './codec.ts';
import type { Role } from './frames.ts';

export const RECOVERY_PACKAGE_VERSION = 1;
export const RECOVERY_AAD = 'secretplay.recovery.v1';
export const MAX_SEALED_BYTES = 64 * 1024;

export interface RecoveryKdfParams {
  name: 'argon2id';
  /** Memory cost in KiB. */
  m: number;
  /** Time cost (iterations). */
  t: number;
  /** Parallelism. */
  p: number;
  dkLen: 32;
}

/** Interactive-login-grade parameters; tuned to stay usable on a mid-range phone. */
export const RECOVERY_KDF: RecoveryKdfParams = { name: 'argon2id', m: 65536, t: 3, p: 1, dkLen: 32 };

export interface SealedRecoveryPackage {
  v: typeof RECOVERY_PACKAGE_VERSION;
  kind: 'sp1-recovery-sealed';
  kdf: RecoveryKdfParams;
  salt: string;
  nonce: string;
  aad: string;
  ct: string;
}

export interface RecoveryPayload {
  pairId: string;
  role: Role;
  oldDeviceId: string;
  oldIdentityPublicKey: string;
  peerDeviceId: string;
  peerPublicKey: string;
  createdAt: number;
  recoveryId: string;
  label: string;
}

const FORBIDDEN_KEY_TOKENS = [
  'message',
  'history',
  'chat',
  'transcript',
  'conversation',
  'sessionkey',
  'ratchet',
  'recording',
  'audio',
  'media',
  'attachment',
  'plaintext',
  'ciphertext',
  'body',
];

export class RecoveryError extends Error {
  readonly code: 'malformed' | 'bad_secret' | 'unsafe_payload';

  constructor(code: 'malformed' | 'bad_secret' | 'unsafe_payload', message: string) {
    super(message);
    this.name = 'RecoveryError';
    this.code = code;
  }
}

function normaliseKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, '');
}

/** Recursively reject content-bearing keys inside a recovery payload. */
export function assertRecoveryPayloadSafe(payload: unknown, path = '$'): void {
  if (Array.isArray(payload)) {
    payload.forEach((entry, index) => assertRecoveryPayloadSafe(entry, `${path}[${index}]`));
    return;
  }
  if (!isRecord(payload)) return;
  for (const [key, value] of Object.entries(payload)) {
    const normalised = normaliseKey(key);
    for (const forbidden of FORBIDDEN_KEY_TOKENS) {
      if (normalised.includes(forbidden)) {
        throw new RecoveryError('unsafe_payload', `recovery payload may not contain "${path}.${key}"`);
      }
    }
    assertRecoveryPayloadSafe(value, `${path}.${key}`);
  }
}

function requireShortString(value: unknown, field: string, min: number, max: number): string {
  if (typeof value !== 'string' || value.length < min || value.length > max) {
    throw new RecoveryError('malformed', `recovery payload has an invalid ${field}`);
  }
  return value;
}

function requirePublicKey(value: unknown, field: string): string {
  if (typeof value !== 'string') throw new RecoveryError('malformed', `recovery payload is missing ${field}`);
  let decoded: Uint8Array;
  try {
    decoded = b64Decode(value);
  } catch {
    throw new RecoveryError('malformed', `recovery payload has an invalid ${field}`);
  }
  if (decoded.length !== 32) throw new RecoveryError('malformed', `recovery payload has an invalid ${field}`);
  return value;
}

export function validateRecoveryPayload(payload: unknown): RecoveryPayload {
  if (!isRecord(payload)) throw new RecoveryError('malformed', 'recovery payload must be an object');
  assertRecoveryPayloadSafe(payload);

  const pairId = requireShortString(payload.pairId, 'pairId', 6, 40);
  const role = payload.role;
  if (role !== 'A' && role !== 'B') throw new RecoveryError('malformed', 'recovery payload has an invalid role');
  const oldDeviceId = requireShortString(payload.oldDeviceId, 'oldDeviceId', 1, 64);
  const peerDeviceId = requireShortString(payload.peerDeviceId, 'peerDeviceId', 1, 64);
  const recoveryId = requireShortString(payload.recoveryId, 'recoveryId', 1, 64);
  const oldIdentityPublicKey = requirePublicKey(payload.oldIdentityPublicKey, 'oldIdentityPublicKey');
  const peerPublicKey = requirePublicKey(payload.peerPublicKey, 'peerPublicKey');

  const createdAt = payload.createdAt;
  if (typeof createdAt !== 'number' || !Number.isSafeInteger(createdAt) || createdAt <= 0) {
    throw new RecoveryError('malformed', 'recovery payload has an invalid createdAt');
  }
  const label = typeof payload.label === 'string' ? payload.label.slice(0, 64) : '';

  return {
    pairId,
    role,
    oldDeviceId,
    oldIdentityPublicKey,
    peerDeviceId,
    peerPublicKey,
    createdAt,
    recoveryId,
    label,
  };
}

function validateKdf(kdf: unknown): RecoveryKdfParams {
  if (!isRecord(kdf)) throw new RecoveryError('malformed', 'sealed package is missing KDF parameters');
  const { name, m, t, p, dkLen } = kdf;
  if (name !== 'argon2id' || dkLen !== 32) {
    throw new RecoveryError('malformed', 'sealed package must use argon2id with a 32-byte key');
  }
  if (typeof m !== 'number' || !Number.isInteger(m) || m < 8 || m > 1_048_576) {
    throw new RecoveryError('malformed', 'sealed package has out-of-range memory cost');
  }
  if (typeof t !== 'number' || !Number.isInteger(t) || t < 1 || t > 16) {
    throw new RecoveryError('malformed', 'sealed package has out-of-range time cost');
  }
  if (typeof p !== 'number' || !Number.isInteger(p) || p < 1 || p > 8) {
    throw new RecoveryError('malformed', 'sealed package has out-of-range parallelism');
  }
  return { name: 'argon2id', m, t, p, dkLen: 32 };
}

function secretBytes(secret: string | Uint8Array): Uint8Array {
  const bytes = typeof secret === 'string' ? utf8(secret) : secret;
  if (bytes.length < 12) throw new RecoveryError('bad_secret', 'recovery secret is too short');
  return bytes;
}

function deriveKey(secret: string | Uint8Array, salt: Uint8Array, kdf: RecoveryKdfParams): Uint8Array {
  return argon2id(secretBytes(secret), salt, { m: kdf.m, t: kdf.t, p: kdf.p, dkLen: 32 });
}

export function sealRecoveryPackage(params: {
  secret: string | Uint8Array;
  payload: RecoveryPayload | Record<string, unknown>;
  kdf?: RecoveryKdfParams;
  aad?: string;
}): SealedRecoveryPackage {
  const validated = validateRecoveryPayload(params.payload);
  const kdf = params.kdf ?? RECOVERY_KDF;
  const salt = randomBytes(16);
  const nonce = randomBytes(24);
  const key = deriveKey(params.secret, salt, kdf);
  const aad = params.aad ?? RECOVERY_AAD;
  const plaintext = utf8(canonicalJson(validated));
  const ciphertext = xchacha20poly1305(key, nonce, utf8(`${aad}|v1`)).encrypt(plaintext);

  return {
    v: RECOVERY_PACKAGE_VERSION,
    kind: 'sp1-recovery-sealed',
    kdf,
    salt: b64(salt),
    nonce: b64(nonce),
    aad,
    ct: b64(ciphertext),
  };
}

export function openRecoveryPackage(params: {
  sealed: unknown;
  secret: string | Uint8Array;
  expectedAad?: string;
}): RecoveryPayload {
  if (!isRecord(params.sealed)) throw new RecoveryError('malformed', 'sealed package must be an object');
  const sealed = params.sealed;
  if (sealed.v !== RECOVERY_PACKAGE_VERSION || sealed.kind !== 'sp1-recovery-sealed') {
    throw new RecoveryError('malformed', 'unsupported recovery package version');
  }
  const kdf = validateKdf(sealed.kdf);
  if (typeof sealed.aad !== 'string' || sealed.aad.length > 64) {
    throw new RecoveryError('malformed', 'sealed package has an invalid aad field');
  }
  if (params.expectedAad !== undefined && sealed.aad !== params.expectedAad) {
    throw new RecoveryError('malformed', 'sealed package aad does not match the expected context');
  }
  if (typeof sealed.salt !== 'string' || typeof sealed.nonce !== 'string' || typeof sealed.ct !== 'string') {
    throw new RecoveryError('malformed', 'sealed package is missing fields');
  }

  let salt: Uint8Array;
  let nonce: Uint8Array;
  let ciphertext: Uint8Array;
  try {
    salt = b64Decode(sealed.salt);
    nonce = b64Decode(sealed.nonce);
    ciphertext = b64Decode(sealed.ct);
  } catch {
    throw new RecoveryError('malformed', 'sealed package has invalid base64 fields');
  }
  if (salt.length !== 16) throw new RecoveryError('malformed', 'sealed package salt must be 16 bytes');
  if (nonce.length !== 24) throw new RecoveryError('malformed', 'sealed package nonce must be 24 bytes');
  if (ciphertext.length === 0 || ciphertext.length > MAX_SEALED_BYTES) {
    throw new RecoveryError('malformed', 'sealed package ciphertext has an invalid size');
  }

  const key = deriveKey(params.secret, salt, kdf);
  let plaintext: Uint8Array;
  try {
    plaintext = xchacha20poly1305(key, nonce, utf8(`${sealed.aad}|v1`)).decrypt(ciphertext);
  } catch {
    throw new RecoveryError('bad_secret', 'recovery package could not be decrypted: wrong secret or tampered data');
  }

  let payload: unknown;
  try {
    payload = JSON.parse(fromUtf8(plaintext));
  } catch {
    throw new RecoveryError('malformed', 'recovery package plaintext is not valid JSON');
  }
  return validateRecoveryPayload(payload);
}

export function newRecoveryId(): string {
  return `r_${b64u(randomBytes(12))}`;
}
