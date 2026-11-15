/**
 * SecretPlay wire protocol, version 1 (`sp1`).
 *
 * The relay is deliberately blind: message and call-signalling payloads are
 * opaque end-to-end-encrypted envelopes produced by vodozemac/Olm on the
 * devices. A relay validates *structure* and *authorization* only.
 *
 * Frame shapes are identical for the Cloudflare Worker and the laptop server;
 * see local_server/protocols/PROTOCOL.md.
 */

import { b64uDecode, isRecord } from './codec.ts';

export const PROTOCOL_ID = 'sp1';
export const PROTOCOL_VERSION = 1;

/** Hard caps. Anything larger is rejected before parsing JSON. */
export const MAX_FRAME_BYTES = 16 * 1024;
export const MAX_CIPHER_BODY_BYTES = 8 * 1024;
export const MAX_ID_CHARS = 64;
export const MAX_PAIR_ID_CHARS = 40;
export const MAX_DEVICE_ID_CHARS = 64;

export type Role = 'A' | 'B';

export function roleForSlot(slot: 1 | 2): Role {
  return slot === 1 ? 'A' : 'B';
}

export function otherRole(role: Role): Role {
  return role === 'A' ? 'B' : 'A';
}

/**
 * Opaque Olm envelope. `senderKey` is the sending device's Curve25519
 * identity key (base64url), `kind` is the Olm message type (0 = pre-key,
 * 1 = normal), `body` is the Olm ciphertext, `msgId` is the sender-chosen
 * id used for replay rejection and UI correlation.
 */
export interface CipherEnvelope {
  senderKey: string;
  kind: 0 | 1;
  body: string;
  msgId: string;
  sentAt: number;
}

export type HelloFrame = {
  v: typeof PROTOCOL_VERSION;
  t: 'hello';
  proto: typeof PROTOCOL_ID;
  pairId: string;
  deviceId: string;
  role: Role;
} & (
  | {
      auth: { kind: 'signed'; ts: number; nonce: string; sig: string };
      /** Signed Olm bootstrap material is mandatory for signed connections. */
      olm: OlmKeys;
    }
  | {
      auth: { kind: 'token'; token: string };
      olm?: OlmKeys;
    }
);

export interface MsgFrame {
  v: typeof PROTOCOL_VERSION;
  t: 'msg';
  id: string;
  cipher: CipherEnvelope;
}

export interface SignalFrame {
  v: typeof PROTOCOL_VERSION;
  t: 'signal';
  id: string;
  cipher: CipherEnvelope;
}

export interface PingFrame {
  v: typeof PROTOCOL_VERSION;
  t: 'ping';
  ts: number;
}

export interface ByeFrame {
  v: typeof PROTOCOL_VERSION;
  t: 'bye';
  reason: 'user_exit' | 'lock' | 'switch_mode';
}

export type ClientFrame = HelloFrame | MsgFrame | SignalFrame | PingFrame | ByeFrame;

/**
 * Curve25519 material needed to bootstrap an Olm session. These are public
 * keys; the relay forwards them but never stores private material. The
 * one-time key is fresh for each session and is used at most once.
 */
export interface OlmKeys {
  identityKey: string;
  oneTimeKey: string;
}

/** Public identity material of the other slot, needed to bootstrap Olm. */
export interface PeerIdentity {
  deviceId: string;
  /** Ed25519 identity key used to authenticate this device on the relay. */
  publicKey: string;
  /** Curve25519 identity key registered for Olm (absent on old registrations). */
  olmIdentityKey?: string;
  /** Curve25519 one-time key offered for the current session, if connected. */
  olmOneTimeKey?: string;
}

export interface WelcomeFrame {
  v: typeof PROTOCOL_VERSION;
  t: 'welcome';
  sessionId: string;
  role: Role;
  peerPresent: boolean;
  /** Present whenever the peer has registered for this pair. */
  peer: PeerIdentity | null;
  serverTime: number;
  heartbeatMs: number;
  sessionTimeoutMs: number;
}

export interface PeerFrame {
  v: typeof PROTOCOL_VERSION;
  t: 'peer';
  state: 'joined' | 'left';
  deviceId?: string;
  publicKey?: string;
  olmIdentityKey?: string;
  olmOneTimeKey?: string;
}

export interface RelayFrame {
  v: typeof PROTOCOL_VERSION;
  t: 'msg' | 'signal';
  id: string;
  seq: number;
  from: Role;
  cipher: CipherEnvelope;
}

export interface PongFrame {
  v: typeof PROTOCOL_VERSION;
  t: 'pong';
  ts: number;
  serverTime: number;
}

export interface EndFrame {
  v: typeof PROTOCOL_VERSION;
  t: 'end';
  reason: EndReason;
}

export interface ErrFrame {
  v: typeof PROTOCOL_VERSION;
  t: 'err';
  code: ErrorCode;
  detail?: string;
}

export type ServerFrame =
  | WelcomeFrame
  | PeerFrame
  | RelayFrame
  | PongFrame
  | EndFrame
  | ErrFrame;

export type EndReason =
  | 'peer_left'
  | 'peer_locked'
  | 'timeout'
  | 'server_shutdown'
  | 'revoked'
  | 'replaced'
  | 'protocol_error';

export type ErrorCode =
  | 'bad_frame'
  | 'unauthorized'
  | 'pair_unknown'
  | 'pair_full'
  | 'slot_taken'
  | 'device_revoked'
  | 'session_required'
  | 'rate_limited'
  | 'replay'
  | 'server_error';

export type ParseResult<T> = { ok: true; frame: T } | { ok: false; code: ErrorCode; detail: string };

const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;
const PAIR_PATTERN = /^[A-Za-z0-9_-]{6,40}$/;

function fail(code: ErrorCode, detail: string): { ok: false; code: ErrorCode; detail: string } {
  return { ok: false, code, detail };
}

function isId(value: unknown, max = MAX_ID_CHARS): value is string {
  return typeof value === 'string' && value.length <= max && ID_PATTERN.test(value);
}

function isTimestamp(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}

function isBase64Url(value: unknown, maxBytes: number, minBytes = 1): value is string {
  if (typeof value !== 'string') return false;
  // Reject obvious oversize before paying for a decode, then check exactly.
  if (value.length > Math.ceil((maxBytes * 4) / 3) + 4) return false;
  try {
    const bytes = b64uDecode(value);
    return bytes.length >= minBytes && bytes.length <= maxBytes;
  } catch {
    return false;
  }
}

/** `undefined` = absent, `invalid` = present but malformed. */
function parseOlmKeys(value: unknown): OlmKeys | undefined | 'invalid' {
  if (value === undefined) return undefined;
  if (!isRecord(value)) return 'invalid';
  const { identityKey, oneTimeKey } = value;
  if (!isBase64Url(identityKey, 32, 32)) return 'invalid';
  if (!isBase64Url(oneTimeKey, 32, 32)) return 'invalid';
  return { identityKey, oneTimeKey };
}

export function validateCipher(value: unknown): ParseResult<CipherEnvelope> {
  if (!isRecord(value)) return fail('bad_frame', 'cipher must be an object');
  const { senderKey, kind, body, msgId, sentAt } = value;
  if (!isBase64Url(senderKey, 48)) return fail('bad_frame', 'cipher.senderKey must be base64url');
  if (kind !== 0 && kind !== 1) return fail('bad_frame', 'cipher.kind must be 0 or 1');
  if (!isBase64Url(body, MAX_CIPHER_BODY_BYTES)) {
    return fail('bad_frame', `cipher.body must be base64url up to ${MAX_CIPHER_BODY_BYTES} bytes`);
  }
  if (!isId(msgId)) return fail('bad_frame', 'cipher.msgId must be a short id');
  if (!isTimestamp(sentAt)) return fail('bad_frame', 'cipher.sentAt must be an integer timestamp');
  return {
    ok: true,
    frame: { senderKey, kind, body, msgId, sentAt },
  };
}

export function parseClientFrame(raw: string): ParseResult<ClientFrame> {
  if (typeof raw !== 'string') return fail('bad_frame', 'frame must be text');
  if (raw.length === 0) return fail('bad_frame', 'empty frame');
  if (raw.length > MAX_FRAME_BYTES) return fail('bad_frame', 'frame too large');

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return fail('bad_frame', 'frame is not valid JSON');
  }
  if (!isRecord(parsed)) return fail('bad_frame', 'frame must be a JSON object');
  if (parsed.v !== PROTOCOL_VERSION) return fail('bad_frame', 'unsupported protocol version');

  switch (parsed.t) {
    case 'hello': {
      if (parsed.proto !== PROTOCOL_ID) return fail('bad_frame', 'unsupported protocol id');
      const { pairId, deviceId, role, auth } = parsed;
      if (typeof pairId !== 'string' || !PAIR_PATTERN.test(pairId)) {
        return fail('bad_frame', 'hello.pairId is malformed');
      }
      if (!isId(deviceId, MAX_DEVICE_ID_CHARS)) return fail('bad_frame', 'hello.deviceId is malformed');
      if (role !== 'A' && role !== 'B') return fail('bad_frame', 'hello.role must be A or B');
      if (!isRecord(auth)) return fail('bad_frame', 'hello.auth is required');
      const olm = parseOlmKeys(parsed.olm);
      if (olm === 'invalid') return fail('bad_frame', 'hello.olm keys must be 32-byte base64url values');

      if (auth.kind === 'signed') {
        if (!olm) return fail('bad_frame', 'signed hello requires authenticated Olm bootstrap keys');
        if (!isTimestamp(auth.ts)) return fail('bad_frame', 'auth.ts must be an integer timestamp');
        if (!isBase64Url(auth.nonce, 32)) return fail('bad_frame', 'auth.nonce must be base64url');
        if (!isBase64Url(auth.sig, 64)) return fail('bad_frame', 'auth.sig must be base64url');
        return {
          ok: true,
          frame: {
            v: 1,
            t: 'hello',
            proto: PROTOCOL_ID,
            pairId,
            deviceId,
            role,
            auth: { kind: 'signed', ts: auth.ts, nonce: auth.nonce, sig: auth.sig },
            olm,
          },
        };
      }
      if (auth.kind === 'token') {
        if (typeof auth.token !== 'string' || auth.token.length > 512) {
          return fail('bad_frame', 'auth.token is malformed');
        }
        return {
          ok: true,
          frame: {
            v: 1,
            t: 'hello',
            proto: PROTOCOL_ID,
            pairId,
            deviceId,
            role,
            auth: { kind: 'token', token: auth.token },
            ...(olm ? { olm } : {}),
          },
        };
      }
      return fail('bad_frame', 'hello.auth.kind must be "signed" or "token"');
    }
    case 'msg':
    case 'signal': {
      const id = parsed.id;
      if (!isId(id)) return fail('bad_frame', `${String(parsed.t)}.id is malformed`);
      const cipher = validateCipher(parsed.cipher);
      if (!cipher.ok) return fail('bad_frame', cipher.detail);
      return {
        ok: true,
        frame: { v: 1, t: parsed.t, id, cipher: cipher.frame },
      };
    }
    case 'ping': {
      if (!isTimestamp(parsed.ts)) return fail('bad_frame', 'ping.ts must be an integer timestamp');
      return { ok: true, frame: { v: 1, t: 'ping', ts: parsed.ts } };
    }
    case 'bye': {
      const reason = parsed.reason;
      if (reason !== 'user_exit' && reason !== 'lock' && reason !== 'switch_mode') {
        return fail('bad_frame', 'bye.reason is invalid');
      }
      return { ok: true, frame: { v: 1, t: 'bye', reason } };
    }
    default:
      return fail('bad_frame', `unknown frame type "${String(parsed.t)}"`);
  }
}

export function encodeFrame(frame: ServerFrame | ClientFrame): string {
  return JSON.stringify(frame);
}
