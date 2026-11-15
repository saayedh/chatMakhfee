/**
 * In-memory pair registry for the laptop relay.
 *
 * Deliberately volatile: restart the server and every pairing, token and
 * session is gone. Exactly two device slots exist. Nothing is written to disk
 * and no message ever reaches this module.
 */

import {
  createInvite,
  deviceIdFromPublicKey,
  hashInviteToken,
  isInviteExpired,
  newPairId,
  type Invite,
} from '../../crypto_core/src/index.ts';
import type { Role } from '../../crypto_core/src/frames.ts';

export interface DeviceRecord {
  deviceId: string;
  role: Role;
  /** Ed25519 identity key, used to authenticate this device. */
  publicKey: Uint8Array;
  /** Curve25519 identity key used by Olm, base64url. Public material only. */
  olmKey: string | null;
  registeredAt: number;
  revokedAt: number | null;
  label: string;
}

export interface InviteState extends Invite {
  usedAt: number | null;
  usedRole: Role | null;
}

export type RegisterErrorCode = 'unauthorized' | 'pair_full' | 'device_revoked' | 'slot_taken';

export type RegisterResult =
  | { ok: true; device: DeviceRecord; reissued: boolean }
  | { ok: false; code: RegisterErrorCode; detail: string };

export interface RegisterInput {
  inviteToken: string;
  deviceId: string;
  publicKey: Uint8Array;
  /** Optional Curve25519 identity key for Olm (public). */
  olmKey?: string;
}

export class PairStore {
  readonly pairId: string;
  readonly createdAt: number;

  private readonly now: () => number;
  private readonly devices = new Map<Role, DeviceRecord>();
  private readonly revoked = new Set<string>();
  private invite: InviteState | null = null;
  private readonly inviteTtlMs: number;

  constructor(options: { now?: () => number; pairId?: string; inviteTtlMs?: number } = {}) {
    this.now = options.now ?? Date.now;
    this.pairId = options.pairId ?? newPairId();
    this.createdAt = this.now();
    this.inviteTtlMs = options.inviteTtlMs ?? 10 * 60 * 1000;
  }

  /** Current usable invitation, or null when both slots are taken. */
  get activeInvite(): InviteState | null {
    if (this.invite === null) return null;
    if (this.invite.usedAt !== null) return null;
    if (isInviteExpired(this.invite, this.now())) return null;
    return this.invite;
  }

  /**
   * Create the next one-time invitation for the next free slot. Returns null
   * when the pair is already complete.
   */
  ensureInvite(): InviteState | null {
    if (this.devices.size >= 2) return null;
    const existing = this.activeInvite;
    if (existing !== null) return existing;
    const invite = createInvite(this.now(), this.inviteTtlMs);
    this.invite = { ...invite, usedAt: null, usedRole: null };
    return this.invite;
  }

  register(input: RegisterInput): RegisterResult {
    const now = this.now();

    if (this.revoked.has(input.deviceId)) {
      return { ok: false, code: 'device_revoked', detail: 'this device was revoked; an operator reset is required' };
    }
    if (input.publicKey.length !== 32) {
      return { ok: false, code: 'unauthorized', detail: 'public key must be 32 bytes' };
    }
    if (deviceIdFromPublicKey(input.publicKey) !== input.deviceId) {
      return { ok: false, code: 'unauthorized', detail: 'deviceId does not match the supplied public key' };
    }

    const existing = this.deviceByDeviceId(input.deviceId);
    if (existing !== null) {
      // Same identity asking again (e.g. app data cleared, token lost). The
      // invite is still required so a random LAN peer cannot re-enter.
      if (!this.consumeInvite(input.inviteToken, now)) {
        return { ok: false, code: 'unauthorized', detail: 'pairing invitation is invalid, expired or already used' };
      }
      existing.publicKey = input.publicKey;
      existing.olmKey = input.olmKey ?? existing.olmKey;
      return { ok: true, device: existing, reissued: true };
    }

    if (this.devices.size >= 2) {
      return { ok: false, code: 'pair_full', detail: 'both authorised device slots are already filled' };
    }
    if (!this.consumeInvite(input.inviteToken, now)) {
      return { ok: false, code: 'unauthorized', detail: 'pairing invitation is invalid, expired or already used' };
    }

    const role: Role = this.devices.has('A') ? 'B' : 'A';
    const device: DeviceRecord = {
      deviceId: input.deviceId,
      role,
      publicKey: input.publicKey,
      olmKey: input.olmKey ?? null,
      registeredAt: now,
      revokedAt: null,
      label: role === 'A' ? 'Phone A' : 'Phone B',
    };
    this.devices.set(role, device);
    return { ok: true, device, reissued: false };
  }

  private consumeInvite(token: string, now: number): boolean {
    const invite = this.invite;
    if (invite === null || invite.usedAt !== null) return false;
    if (isInviteExpired(invite, now)) return false;
    if (hashInviteToken(token) !== invite.hash) return false;
    invite.usedAt = now;
    this.invite = null;
    return true;
  }

  getDevice(role: Role): DeviceRecord | null {
    return this.devices.get(role) ?? null;
  }

  deviceByDeviceId(deviceId: string): DeviceRecord | null {
    for (const device of this.devices.values()) {
      if (device.deviceId === deviceId) return device;
    }
    return null;
  }

  get slotsFilled(): number {
    return this.devices.size;
  }

  get isComplete(): boolean {
    return this.devices.size === 2;
  }

  isRevoked(deviceId: string): boolean {
    return this.revoked.has(deviceId);
  }

  revoke(role: Role): DeviceRecord | null {
    const device = this.devices.get(role);
    if (!device) return null;
    this.revoked.add(device.deviceId);
    device.revokedAt = this.now();
    this.devices.delete(role);
    // The slot can be repopulated by a *new* identity, but the revoked device id
    // stays on the deny list so its old keys can never be used again.
    this.invite = null;
    return device;
  }

  reset(): void {
    this.devices.clear();
    this.revoked.clear();
    this.invite = null;
  }

  /** Redacted view for logs/tests: never includes key bytes or invite secrets. */
  snapshot(): Record<string, unknown> {
    return {
      pairId: this.pairId,
      createdAt: this.createdAt,
      slotsFilled: this.devices.size,
      devices: [...this.devices.values()].map((device) => ({
        role: device.role,
        deviceId: device.deviceId,
        registeredAt: device.registeredAt,
        revokedAt: device.revokedAt,
        label: device.label,
      })),
      invite: this.activeInvite ? { expiresAt: this.activeInvite.expiresAt, usedAt: this.activeInvite.usedAt } : null,
    };
  }
}
