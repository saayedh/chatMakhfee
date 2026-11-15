/**
 * Pure decisions shared by the Durable Object and its tests, plus the schema
 * guard that keeps the cloud relay metadata-only.
 *
 * The schema guard is deliberate defence in depth: if anyone ever adds a
 * `messages` table, `npm test` fails and deployment is refused by
 * scripts/deploy-cloudflare.bat.
 */

import type { ErrorCode, Role } from '../../crypto_core/src/frames.ts';

export interface RegistrationSnapshot {
  devicesStored: number;
  claimedDeviceId: string;
  derivedDeviceId: string;
  publicKeyBytes: number;
  alreadyRegisteredRole: Role | null;
  inviteUsable: boolean;
  targetSlotFree: boolean;
}

export type RegistrationPlan =
  | { ok: true; role: Role; reissued: boolean }
  | { ok: false; code: ErrorCode; detail: string };

/**
 * Decide whether a registration attempt may proceed.
 *
 * Order matters: identity binding first, then the invite, then capacity, so a
 * caller cannot learn pair capacity without a valid invitation.
 */
export function planRegistration(snapshot: RegistrationSnapshot): RegistrationPlan {
  if (snapshot.publicKeyBytes !== 32) {
    return { ok: false, code: 'unauthorized', detail: 'public key must be 32 bytes' };
  }
  if (snapshot.derivedDeviceId !== snapshot.claimedDeviceId) {
    return { ok: false, code: 'unauthorized', detail: 'deviceId does not match the supplied public key' };
  }
  if (!snapshot.inviteUsable) {
    return { ok: false, code: 'unauthorized', detail: 'pairing invitation is invalid, expired or already used' };
  }
  if (snapshot.alreadyRegisteredRole !== null) {
    return { ok: true, role: snapshot.alreadyRegisteredRole, reissued: true };
  }
  if (snapshot.devicesStored >= 2 || !snapshot.targetSlotFree) {
    return { ok: false, code: 'pair_full', detail: 'both authorised device slots are already filled' };
  }
  return { ok: true, role: snapshot.devicesStored === 0 ? 'A' : 'B', reissued: false };
}

/**
 * The complete cloud schema. Four metadata tables, nothing else. There is no
 * table (and must never be a table) for messages, ciphertext, attachments,
 * call data or transcripts.
 */
export const SCHEMA_STATEMENTS: readonly string[] = [
  `CREATE TABLE IF NOT EXISTS pairs (
     pair_id TEXT PRIMARY KEY,
     created_at INTEGER NOT NULL
   )`,
  `CREATE TABLE IF NOT EXISTS devices (
     pair_id TEXT NOT NULL,
     role TEXT NOT NULL CHECK (role IN ('A','B')),
     device_id TEXT NOT NULL,
     public_key TEXT NOT NULL,
     olm_key TEXT,
     registered_at INTEGER NOT NULL,
     PRIMARY KEY (pair_id, role)
   )`,
  `CREATE TABLE IF NOT EXISTS invites (
     pair_id TEXT NOT NULL,
     hash TEXT NOT NULL,
     created_at INTEGER NOT NULL,
     expires_at INTEGER NOT NULL,
     used_at INTEGER,
     PRIMARY KEY (pair_id, hash)
   )`,
  `CREATE TABLE IF NOT EXISTS revocations (
     pair_id TEXT NOT NULL,
     device_id TEXT NOT NULL,
     revoked_at INTEGER NOT NULL,
     PRIMARY KEY (pair_id, device_id)
   )`,
] as const;

const ALLOWED_TABLES = new Set(['pairs', 'devices', 'invites', 'revocations']);
const FORBIDDEN_TABLE_TOKENS = ['message', 'history', 'transcript', 'attachment', 'call', 'media', 'queue', 'chat'];

export class SchemaViolation extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SchemaViolation';
  }
}

/** Throws when the schema contains anything beyond minimal metadata. */
export function assertMetadataOnlySchema(statements: readonly string[] = SCHEMA_STATEMENTS): void {
  for (const statement of statements) {
    const match = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z0-9_]+)/i.exec(statement);
    if (!match) {
      if (/^\s*(CREATE|ALTER)\s/i.test(statement)) {
        throw new SchemaViolation(`unexpected schema statement: ${statement.slice(0, 60)}`);
      }
      continue;
    }
    const table = (match[1] ?? '').toLowerCase();
    if (!ALLOWED_TABLES.has(table)) {
      throw new SchemaViolation(`table "${table}" is not part of the metadata-only schema`);
    }
    for (const token of FORBIDDEN_TABLE_TOKENS) {
      if (table.includes(token)) {
        throw new SchemaViolation(`table "${table}" looks like conversation data and is forbidden`);
      }
    }
  }
}
