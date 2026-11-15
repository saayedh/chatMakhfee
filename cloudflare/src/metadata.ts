/**
 * SQLite metadata for one pair, inside the pair's Durable Object.
 *
 * Only identity and invitation metadata is stored. Ciphertext is relayed
 * through the room machine and dropped; it is never passed to this module.
 */

import { hashInviteToken, type Role } from '../../crypto_core/src/index.ts';
import { SCHEMA_STATEMENTS, assertMetadataOnlySchema } from './protocol_rules.ts';

export type SqlParam = string | number | null;

export interface SqlCursor {
  toArray(): Record<string, unknown>[];
}

export interface SqlStorageLike {
  exec(sql: string, ...params: SqlParam[]): SqlCursor;
}

export interface DeviceRow {
  role: Role;
  deviceId: string;
  publicKey: string;
  /** Curve25519 identity key for Olm (public); null for legacy rows. */
  olmKey: string | null;
  registeredAt: number;
}

export interface InviteRow {
  hash: string;
  expiresAt: number;
}

function asString(value: unknown, field: string): string {
  if (typeof value !== 'string') throw new Error(`metadata: ${field} is not a string`);
  return value;
}

function asNumber(value: unknown, field: string): number {
  if (typeof value !== 'number') throw new Error(`metadata: ${field} is not a number`);
  return value;
}

export class PairMetadata {
  private readonly sql: SqlStorageLike;
  private readonly now: () => number;
  private migrated = false;

  constructor(sql: SqlStorageLike, now: () => number = Date.now) {
    this.sql = sql;
    this.now = now;
  }

  migrate(): void {
    if (this.migrated) return;
    assertMetadataOnlySchema();
    for (const statement of SCHEMA_STATEMENTS) this.sql.exec(statement);
    this.migrated = true;
  }

  ensurePair(pairId: string): void {
    this.sql.exec(
      'INSERT OR IGNORE INTO pairs (pair_id, created_at) VALUES (?, ?)',
      pairId,
      this.now(),
    );
  }

  hasPair(pairId: string): boolean {
    return this.sql.exec('SELECT pair_id FROM pairs WHERE pair_id = ?', pairId).toArray().length > 0;
  }

  countDevices(pairId: string): number {
    const rows = this.sql.exec('SELECT COUNT(*) AS n FROM devices WHERE pair_id = ?', pairId).toArray();
    return asNumber(rows[0]?.n, 'count');
  }

  private static rowToDevice(row: Record<string, unknown>): DeviceRow {
    return {
      role: asString(row.role, 'role') as Role,
      deviceId: asString(row.device_id, 'device_id'),
      publicKey: asString(row.public_key, 'public_key'),
      olmKey: typeof row.olm_key === 'string' ? row.olm_key : null,
      registeredAt: asNumber(row.registered_at, 'registered_at'),
    };
  }

  deviceFor(pairId: string, role: Role): DeviceRow | null {
    const rows = this.sql
      .exec(
        'SELECT role, device_id, public_key, olm_key, registered_at FROM devices WHERE pair_id = ? AND role = ?',
        pairId,
        role,
      )
      .toArray();
    const row = rows[0];
    return row ? PairMetadata.rowToDevice(row) : null;
  }

  deviceById(pairId: string, deviceId: string): DeviceRow | null {
    const rows = this.sql
      .exec(
        'SELECT role, device_id, public_key, olm_key, registered_at FROM devices WHERE pair_id = ? AND device_id = ?',
        pairId,
        deviceId,
      )
      .toArray();
    const row = rows[0];
    return row ? PairMetadata.rowToDevice(row) : null;
  }

  putDevice(
    pairId: string,
    role: Role,
    deviceId: string,
    publicKey: string,
    olmKey: string | null = null,
  ): void {
    this.sql.exec(
      `INSERT INTO devices (pair_id, role, device_id, public_key, olm_key, registered_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(pair_id, role) DO UPDATE SET device_id = excluded.device_id,
                                                public_key = excluded.public_key,
                                                olm_key = excluded.olm_key,
                                                registered_at = excluded.registered_at`,
      pairId,
      role,
      deviceId,
      publicKey,
      olmKey,
      this.now(),
    );
  }

  /** Store only the invitation hash; the token itself is never persisted. */
  createInvite(pairId: string, token: string, ttlMs: number): InviteRow {
    const now = this.now();
    const hash = hashInviteToken(token);
    const expiresAt = now + ttlMs;
    this.sql.exec(
      'INSERT OR REPLACE INTO invites (pair_id, hash, created_at, expires_at, used_at) VALUES (?, ?, ?, ?, NULL)',
      pairId,
      hash,
      now,
      expiresAt,
    );
    return { hash, expiresAt };
  }

  consumeInvite(pairId: string, token: string): boolean {
    const now = this.now();
    const hash = hashInviteToken(token);
    const rows = this.sql
      .exec(
        'SELECT hash FROM invites WHERE pair_id = ? AND hash = ? AND used_at IS NULL AND expires_at > ?',
        pairId,
        hash,
        now,
      )
      .toArray();
    if (rows.length === 0) return false;
    this.sql.exec('UPDATE invites SET used_at = ? WHERE pair_id = ? AND hash = ?', now, pairId, hash);
    return true;
  }

  activeInvite(pairId: string): InviteRow | null {
    const rows = this.sql
      .exec(
        'SELECT hash, expires_at FROM invites WHERE pair_id = ? AND used_at IS NULL AND expires_at > ? ORDER BY created_at DESC LIMIT 1',
        pairId,
        this.now(),
      )
      .toArray();
    const row = rows[0];
    if (!row) return null;
    return { hash: asString(row.hash, 'hash'), expiresAt: asNumber(row.expires_at, 'expires_at') };
  }

  revokeDevice(pairId: string, role: Role): DeviceRow | null {
    const device = this.deviceFor(pairId, role);
    if (!device) return null;
    this.sql.exec('DELETE FROM devices WHERE pair_id = ? AND role = ?', pairId, role);
    this.sql.exec(
      'INSERT OR REPLACE INTO revocations (pair_id, device_id, revoked_at) VALUES (?, ?, ?)',
      pairId,
      device.deviceId,
      this.now(),
    );
    return device;
  }

  isRevoked(pairId: string, deviceId: string): boolean {
    return (
      this.sql
        .exec('SELECT device_id FROM revocations WHERE pair_id = ? AND device_id = ?', pairId, deviceId)
        .toArray().length > 0
    );
  }

  /** Redacted snapshot for `/state` and logs: no keys, no invite secrets. */
  snapshot(pairId: string): Record<string, unknown> {
    const devices = this.sql
      .exec('SELECT role, device_id, registered_at FROM devices WHERE pair_id = ? ORDER BY role', pairId)
      .toArray()
      .map((row) => ({
        role: asString(row.role, 'role'),
        deviceId: asString(row.device_id, 'device_id'),
        registeredAt: asNumber(row.registered_at, 'registered_at'),
      }));
    const invite = this.activeInvite(pairId);
    return {
      pairId,
      slotsFilled: devices.length,
      devices,
      invite: invite ? { expiresAt: invite.expiresAt } : null,
    };
  }
}
