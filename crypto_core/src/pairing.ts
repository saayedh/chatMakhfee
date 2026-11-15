/**
 * One-time pairing invitations and the informational pairing fingerprint.
 *
 * The authoritative "are we talking to the right person" check is the Olm SAS
 * comparison inside the app (vodozemac `Sas`), which never touches the server.
 * The fingerprint below is a convenience for the laptop console only and is
 * explicitly *not* a trust anchor.
 */

import { b64u, b64uDecode, randomBytes, sha256, sha256Hex, utf8, canonicalJson } from './codec.ts';

export const INVITE_TTL_MS = 10 * 60 * 1000;
export const INVITE_BYTES = 24;

export interface Invite {
  /** Secret handed to the phones (inside the QR payload). */
  token: string;
  /** What the server stores instead of the secret. */
  hash: string;
  createdAt: number;
  expiresAt: number;
}

export function createInvite(now: number = Date.now(), ttlMs: number = INVITE_TTL_MS): Invite {
  const token = b64u(randomBytes(INVITE_BYTES));
  return {
    token,
    hash: hashInviteToken(token),
    createdAt: now,
    expiresAt: now + ttlMs,
  };
}

export function hashInviteToken(token: string): string {
  return sha256Hex(`secretplay.invite.v1|${token}`);
}

export function isValidInviteToken(token: string): boolean {
  if (typeof token !== 'string') return false;
  try {
    return b64uDecode(token).length === INVITE_BYTES;
  } catch {
    return false;
  }
}

export function isInviteExpired(invite: Pick<Invite, 'expiresAt'>, now: number = Date.now()): boolean {
  return now >= invite.expiresAt;
}

/**
 * 12-digit fingerprint of both public identity keys, order independent.
 * Displayed as `1234 5678 9012`. Informational only.
 */
export function pairingFingerprint(publicKeyA: Uint8Array, publicKeyB: Uint8Array): string {
  const [first, second] =
    b64u(publicKeyA) <= b64u(publicKeyB) ? [publicKeyA, publicKeyB] : [publicKeyB, publicKeyA];
  const joined = new Uint8Array(first.length + second.length);
  joined.set(first, 0);
  joined.set(second, first.length);
  const digest = sha256(utf8(canonicalJson({ domain: 'secretplay.fingerprint.v1', keys: b64u(joined) })));
  let out = '';
  for (let i = 0; i < 3; i += 1) {
    const slice = digest.subarray(i * 4, i * 4 + 4);
    const combined =
      (((slice[0] as number) * 256 + (slice[1] as number)) * 256 + (slice[2] as number)) * 256 +
      (slice[3] as number);
    out += String(combined % 10000).padStart(4, '0');
  }
  return `${out.slice(0, 4)} ${out.slice(4, 8)} ${out.slice(8, 12)}`;
}

/** Payload encoded in the laptop's QR code (local / offline mode). */
export interface PairingQrLocal {
  v: 1;
  proto: 'sp1';
  mode: 'local';
  wsUrl: string;
  httpUrl: string;
  pairId: string;
  invite: string;
  expiresAt: number;
}

/** Payload encoded in the first device's QR code (Cloudflare mode). */
export interface PairingQrCloud {
  v: 1;
  proto: 'sp1';
  mode: 'cloud';
  wsUrl: string;
  pairId: string;
  invite: string;
  expiresAt: number;
}

export type PairingQr = PairingQrLocal | PairingQrCloud;

export function encodePairingQr(qr: PairingQr): string {
  const validated = validatePairingQr(qr);
  return canonicalJson(validated);
}

function validatePairingQr(value: unknown): PairingQr {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new TypeError('pairing QR must be an object');
  }
  const qr = value as Record<string, unknown>;
  if (qr.v !== 1 || qr.proto !== 'sp1') throw new TypeError('pairing QR has an unsupported version');
  if (qr.mode !== 'local' && qr.mode !== 'cloud') throw new TypeError('pairing QR has an unknown mode');
  if (typeof qr.pairId !== 'string' || !/^[A-Za-z0-9_-]{6,40}$/.test(qr.pairId)) {
    throw new TypeError('pairing QR has a malformed pairId');
  }
  if (!isValidInviteToken(String(qr.invite))) throw new TypeError('pairing QR has a malformed invite');
  if (typeof qr.expiresAt !== 'number' || !Number.isSafeInteger(qr.expiresAt) || qr.expiresAt <= 0) {
    throw new TypeError('pairing QR has a malformed expiry');
  }
  if (typeof qr.wsUrl !== 'string') throw new TypeError('pairing QR is missing wsUrl');

  if (qr.mode === 'local') {
    // Local mode is a trusted-LAN transport; the session is E2EE regardless.
    if (!qr.wsUrl.startsWith('ws://')) throw new TypeError('local pairing QR must use ws://');
    if (typeof qr.httpUrl !== 'string' || !qr.httpUrl.startsWith('http://')) {
      throw new TypeError('local pairing QR must carry an http:// base URL');
    }
    return {
      v: 1,
      proto: 'sp1',
      mode: 'local',
      wsUrl: qr.wsUrl,
      httpUrl: qr.httpUrl,
      pairId: qr.pairId,
      invite: qr.invite as string,
      expiresAt: qr.expiresAt,
    };
  }

  if (!qr.wsUrl.startsWith('wss://')) throw new TypeError('cloud pairing QR must use wss://');
  return {
    v: 1,
    proto: 'sp1',
    mode: 'cloud',
    wsUrl: qr.wsUrl,
    pairId: qr.pairId,
    invite: qr.invite as string,
    expiresAt: qr.expiresAt,
  };
}

export function parsePairingQr(text: string): { ok: true; qr: PairingQr } | { ok: false; detail: string } {
  if (typeof text !== 'string' || text.length === 0 || text.length > 2048) {
    return { ok: false, detail: 'pairing QR text is empty or too large' };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false, detail: 'pairing QR is not valid JSON' };
  }
  try {
    return { ok: true, qr: validatePairingQr(parsed) };
  } catch (error) {
    return { ok: false, detail: error instanceof Error ? error.message : 'pairing QR is invalid' };
  }
}

/** Short pretty pair id, e.g. `pair-7K2M-9QX4`. Not a secret. */
export function newPairId(): string {
  const bytes = randomBytes(10);
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let body = '';
  for (const byte of bytes) body += alphabet[byte % alphabet.length];
  return `pair-${body.slice(0, 4)}-${body.slice(4, 8)}-${body.slice(8, 10)}`;
}
