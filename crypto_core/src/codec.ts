/**
 * Encoding, hashing and comparison helpers shared by both relays.
 *
 * Everything here is portable across Node.js and the Cloudflare Workers
 * runtime: no `node:crypto`, no Buffer, no filesystem.
 */

import { sha256 as nobleSha256 } from '@noble/hashes/sha2.js';
import { hmac } from '@noble/hashes/hmac.js';

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

export function utf8(value: string): Uint8Array {
  return textEncoder.encode(value);
}

export function fromUtf8(bytes: Uint8Array): string {
  return textDecoder.decode(bytes);
}

/** Deterministic JSON: sorted object keys, no whitespace, no undefined. */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

function canonicalize(value: unknown): unknown {
  if (value === null) return null;
  const type = typeof value;
  if (type === 'string' || type === 'boolean') return value;
  if (type === 'number') {
    if (!Number.isFinite(value as number)) {
      throw new TypeError('canonicalJson: non-finite numbers are not allowed');
    }
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalize);
  if (type === 'object') {
    const source = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(source).sort()) {
      const entry = source[key];
      if (entry === undefined) continue;
      out[key] = canonicalize(entry);
    }
    return out;
  }
  throw new TypeError(`canonicalJson: unsupported value type "${type}"`);
}

function toBinaryString(bytes: Uint8Array): string {
  let out = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    out += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return out;
}

/** URL-safe base64 without padding (what travels on the wire). */
export function b64u(bytes: Uint8Array): string {
  return btoa(toBinaryString(bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function b64uDecode(value: string): Uint8Array {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]*$/.test(value)) {
    throw new TypeError('b64uDecode: not url-safe base64');
  }
  const padding = value.length % 4 === 0 ? '' : '='.repeat(4 - (value.length % 4));
  const binary = atob(value.replace(/-/g, '+').replace(/_/g, '/') + padding);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i);
  return out;
}

/** Standard base64 (used inside sealed recovery packages only). */
export function b64(bytes: Uint8Array): string {
  return btoa(toBinaryString(bytes));
}

export function b64Decode(value: string): Uint8Array {
  const binary = atob(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i);
  return out;
}

export function randomBytes(length: number): Uint8Array {
  if (!Number.isInteger(length) || length <= 0 || length > 4096) {
    throw new RangeError('randomBytes: length must be 1..4096');
  }
  const out = new Uint8Array(length);
  const max = 65536;
  for (let offset = 0; offset < length; offset += max) {
    crypto.getRandomValues(out.subarray(offset, Math.min(offset + max, length)));
  }
  return out;
}

export function sha256(data: Uint8Array | string): Uint8Array {
  return nobleSha256(typeof data === 'string' ? utf8(data) : data);
}

export function sha256Hex(data: Uint8Array | string): string {
  return [...sha256(data)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export function hmacSha256(key: Uint8Array, data: Uint8Array | string): Uint8Array {
  return hmac(nobleSha256, key, typeof data === 'string' ? utf8(data) : data);
}

/** Constant-time comparison for MACs, tokens and signatures. */
export function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= (a[i] as number) ^ (b[i] as number);
  return diff === 0;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** RFC 4122 v4 UUID, used as an opaque instance/identifier string. */
export function uuidv4(): string {
  const bytes = randomBytes(16);
  bytes[6] = ((bytes[6] as number) & 0x0f) | 0x40;
  bytes[8] = ((bytes[8] as number) & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
