/**
 * Device authentication and short-lived session credentials.
 *
 * Two transports, one meaning: "prove you are one of the two devices of this
 * pair, right now".
 *
 *  - `signed`  — Ed25519 signature over a canonical hello payload. Used in
 *                Cloudflare mode, where the relay stores each device's public
 *                identity key and never a shared secret.
 *  - `token`   — HMAC session token minted by the laptop server after the QR
 *                pairing handshake. Used in local/offline mode, where the
 *                laptop is the only trust anchor and there is no network.
 */

import { ed25519 } from '@noble/curves/ed25519.js';
import {
  b64u,
  b64uDecode,
  canonicalJson,
  isRecord,
  randomBytes,
  sha256,
  timingSafeEqual,
  hmacSha256,
  utf8,
  fromUtf8,
} from './codec.ts';
import { PROTOCOL_ID, PROTOCOL_VERSION, type Role } from './frames.ts';

/** How far a client clock may drift from the relay before a hello is refused. */
export const MAX_HELLO_SKEW_MS = 120_000;

/** Default lifetime of a local-mode session token. */
export const DEFAULT_SESSION_TTL_MS = 12 * 60 * 60 * 1000;

export interface HelloSigningInput {
  pairId: string;
  deviceId: string;
  role: Role;
  ts: number;
  nonce: string;
  /** Public Olm bootstrap keys are mandatory and authenticated as part of the hello. */
  olm: { identityKey: string; oneTimeKey: string };
}

/** Domain-separated, unambiguous payload for hello signatures. */
export function helloSigningPayload(input: HelloSigningInput): Uint8Array {
  return utf8(
    canonicalJson({
      domain: 'secretplay.hello.v1',
      proto: PROTOCOL_ID,
      v: PROTOCOL_VERSION,
      pairId: input.pairId,
      deviceId: input.deviceId,
      role: input.role,
      ts: input.ts,
      nonce: input.nonce,
      olm: { identityKey: input.olm.identityKey, oneTimeKey: input.olm.oneTimeKey },
    }),
  );
}

export function createDeviceIdentity(): { secretKey: Uint8Array; publicKey: Uint8Array; deviceId: string } {
  const secretKey = ed25519.utils.randomSecretKey();
  const publicKey = ed25519.getPublicKey(secretKey);
  return { secretKey, publicKey, deviceId: deviceIdFromPublicKey(publicKey) };
}

/** Stable device id derived from the public key (no server-side mapping needed). */
export function deviceIdFromPublicKey(publicKey: Uint8Array): string {
  return `d_${b64u(sha256(publicKey).subarray(0, 16))}`;
}

export function signHello(secretKey: Uint8Array, input: HelloSigningInput): string {
  return b64u(ed25519.sign(helloSigningPayload(input), secretKey));
}

export function newHelloNonce(): string {
  return b64u(randomBytes(16));
}

export type VerifyHelloResult =
  | { ok: true }
  | { ok: false; code: 'unauthorized' | 'replay'; detail: string };

/**
 * Verify a `signed` hello against the device's registered public key.
 * Replay protection is the caller's job (per-pair `ReplayGuard`), because the
 * nonce cache must be scoped to the room, not to this module.
 */
export function verifySignedHello(params: {
  publicKey: Uint8Array;
  pairId: string;
  deviceId: string;
  role: Role;
  auth: { ts: number; nonce: string; sig: string };
  /** Must be the exact public Olm material carried by the signed hello frame. */
  olm: { identityKey: string; oneTimeKey: string };
  now: number;
  maxSkewMs?: number;
}): VerifyHelloResult {
  const { publicKey, pairId, deviceId, role, auth, now, olm } = params;
  const maxSkew = params.maxSkewMs ?? MAX_HELLO_SKEW_MS;

  if (Math.abs(now - auth.ts) > maxSkew) {
    return { ok: false, code: 'unauthorized', detail: 'hello timestamp outside the allowed window' };
  }
  if (deviceIdFromPublicKey(publicKey) !== deviceId) {
    return { ok: false, code: 'unauthorized', detail: 'deviceId does not match the registered public key' };
  }

  let signature: Uint8Array;
  let nonce: Uint8Array;
  try {
    signature = b64uDecode(auth.sig);
    nonce = b64uDecode(auth.nonce);
  } catch {
    return { ok: false, code: 'unauthorized', detail: 'malformed signature or nonce encoding' };
  }
  if (signature.length !== 64) return { ok: false, code: 'unauthorized', detail: 'signature must be 64 bytes' };
  if (nonce.length < 16 || nonce.length > 32) {
    return { ok: false, code: 'unauthorized', detail: 'nonce must be 16..32 bytes' };
  }

  const payload = helloSigningPayload({ pairId, deviceId, role, ts: auth.ts, nonce: auth.nonce, olm });
  let valid = false;
  try {
    valid = ed25519.verify(signature, payload, publicKey);
  } catch {
    valid = false;
  }
  if (!valid) return { ok: false, code: 'unauthorized', detail: 'hello signature is invalid' };
  return { ok: true };
}

/**
 * Bounded replay cache. Keys are short strings (nonce or frame id) held only in
 * memory for `ttlMs`; the cache never grows without limit.
 */
export class ReplayGuard {
  private readonly ttlMs: number;
  private readonly maxEntries: number;
  private readonly seen = new Map<string, number>();

  constructor(options: { ttlMs?: number; maxEntries?: number } = {}) {
    this.ttlMs = options.ttlMs ?? 10 * 60 * 1000;
    this.maxEntries = options.maxEntries ?? 4096;
  }

  /** Returns true exactly once per unseen key inside the TTL window. */
  check(key: string, now: number = Date.now()): boolean {
    this.prune(now);
    const previous = this.seen.get(key);
    if (previous !== undefined && now - previous <= this.ttlMs) return false;
    this.seen.set(key, now);
    if (this.seen.size > this.maxEntries) {
      const oldest = this.seen.keys().next();
      if (!oldest.done) this.seen.delete(oldest.value);
    }
    return true;
  }

  prune(now: number = Date.now()): void {
    for (const [key, at] of this.seen) {
      if (now - at > this.ttlMs) this.seen.delete(key);
      else break; // insertion order: everything after this is newer
    }
  }

  get size(): number {
    return this.seen.size;
  }

  clear(): void {
    this.seen.clear();
  }
}

export interface SessionClaims {
  pairId: string;
  deviceId: string;
  role: Role;
  iat: number;
  exp: number;
  jti: string;
}

const TOKEN_PREFIX = 'sp1t';

export function issueSessionToken(params: {
  secret: Uint8Array;
  pairId: string;
  deviceId: string;
  role: Role;
  ttlMs?: number;
  now?: number;
}): { token: string; claims: SessionClaims } {
  const now = params.now ?? Date.now();
  const claims: SessionClaims = {
    pairId: params.pairId,
    deviceId: params.deviceId,
    role: params.role,
    iat: now,
    exp: now + (params.ttlMs ?? DEFAULT_SESSION_TTL_MS),
    jti: b64u(randomBytes(8)),
  };
  const payload = b64u(utf8(canonicalJson(claims)));
  const mac = b64u(hmacSha256(params.secret, `${TOKEN_PREFIX}.${payload}`));
  return { token: `${TOKEN_PREFIX}.${payload}.${mac}`, claims };
}

export type VerifyTokenResult =
  | { ok: true; claims: SessionClaims }
  | { ok: false; code: 'unauthorized'; detail: string };

export function verifySessionToken(params: {
  secret: Uint8Array;
  token: string;
  now?: number;
  pairId?: string;
  deviceId?: string;
  role?: Role;
}): VerifyTokenResult {
  const now = params.now ?? Date.now();
  const parts = params.token.split('.');
  if (parts.length !== 3 || parts[0] !== TOKEN_PREFIX) {
    return { ok: false, code: 'unauthorized', detail: 'session token is malformed' };
  }
  const [, payload, mac] = parts as [string, string, string];

  let expectedMac: Uint8Array;
  try {
    expectedMac = hmacSha256(params.secret, `${TOKEN_PREFIX}.${payload}`);
  } catch {
    return { ok: false, code: 'unauthorized', detail: 'session token is malformed' };
  }

  let providedMac: Uint8Array;
  let claims: unknown;
  try {
    providedMac = b64uDecode(mac);
    claims = JSON.parse(fromUtf8(b64uDecode(payload)));
  } catch {
    return { ok: false, code: 'unauthorized', detail: 'session token is malformed' };
  }

  if (!timingSafeEqual(expectedMac, providedMac)) {
    return { ok: false, code: 'unauthorized', detail: 'session token MAC is invalid' };
  }
  if (
    !isRecord(claims) ||
    typeof claims.pairId !== 'string' ||
    typeof claims.deviceId !== 'string' ||
    (claims.role !== 'A' && claims.role !== 'B') ||
    typeof claims.iat !== 'number' ||
    typeof claims.exp !== 'number' ||
    typeof claims.jti !== 'string'
  ) {
    return { ok: false, code: 'unauthorized', detail: 'session claims are malformed' };
  }
  if (now >= claims.exp) return { ok: false, code: 'unauthorized', detail: 'session token has expired' };
  if (params.pairId !== undefined && claims.pairId !== params.pairId) {
    return { ok: false, code: 'unauthorized', detail: 'session token belongs to a different pair' };
  }
  if (params.deviceId !== undefined && claims.deviceId !== params.deviceId) {
    return { ok: false, code: 'unauthorized', detail: 'session token belongs to a different device' };
  }
  if (params.role !== undefined && claims.role !== params.role) {
    return { ok: false, code: 'unauthorized', detail: 'session token belongs to a different slot' };
  }

  return {
    ok: true,
    claims: {
      pairId: claims.pairId,
      deviceId: claims.deviceId,
      role: claims.role,
      iat: claims.iat,
      exp: claims.exp,
      jti: claims.jti,
    },
  };
}
