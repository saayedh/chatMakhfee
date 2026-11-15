/**
 * The room machine: the single implementation of SecretPlay's relay rules,
 * shared by the Cloudflare Durable Object and the laptop server.
 *
 * Rules:
 *  - a session exists only while *both* authorised devices are connected;
 *  - ciphertext is relayed immediately and never retained or queued;
 *  - duplicate frame ids from the same role are rejected (`replay`);
 *  - silence beyond the session timeout ends the session for both devices;
 *  - ending a session deletes its runtime, so nothing can be recovered.
 *
 * Transport-agnostic on purpose: `SocketLike` is the two methods the machine
 * needs, so the same code is exercised by WebSocket relays and unit tests.
 */

import { ReplayGuard } from './auth.ts';
import { encodeFrame, parseClientFrame, otherRole } from './frames.ts';
import type {
  CipherEnvelope,
  EndReason,
  ErrorCode,
  OlmKeys,
  PeerIdentity,
  Role,
  ServerFrame,
  WelcomeFrame,
} from './frames.ts';
import { uuidv4 } from './codec.ts';

export interface SocketLike {
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

export interface RoomConfig {
  heartbeatMs: number;
  sessionTimeoutMs: number;
  ratePerMinute: number;
}

export interface IdentityDirectory {
  identityFor(role: Role): PeerIdentity | null;
  isRevoked(deviceId: string): boolean;
}

export interface AttachInput {
  pairId: string;
  role: Role;
  deviceId: string;
  socket: SocketLike;
  /** Reuse an existing session id when rehydrating after hibernation. */
  sessionId?: string;
  /** Restore the last heartbeat time when rehydrating after hibernation. */
  lastSeen?: number;
  /** True when rebuilding state from hibernated sockets: notify nobody. */
  rehydrate?: boolean;
  /** Public Olm material announced in the device's hello. */
  olm?: OlmKeys;
}

export interface AttachResult {
  sessionId: string;
  welcome: WelcomeFrame;
}

/** Client-side closing code meaning "session over, lock the UI". */
export const CLOSE_SESSION_ENDED = 4000;
export const CLOSE_REPLACED = 4001;

interface Member {
  role: Role;
  deviceId: string;
  socket: SocketLike;
  joinedAt: number;
  lastSeen: number;
  windowStart: number;
  windowCount: number;
  overLimit: number;
  olm?: OlmKeys;
}

interface PairRuntime {
  pairId: string;
  sessionId: string;
  seq: number;
  members: Partial<Record<Role, Member>>;
  seen: ReplayGuard;
}

export class RoomMachine {
  private readonly pairs = new Map<string, PairRuntime>();
  private readonly config: RoomConfig;
  private readonly directory: IdentityDirectory;
  private readonly now: () => number;
  private readonly log: (event: string, fields?: Record<string, unknown>) => void;

  constructor(deps: {
    config: RoomConfig;
    directory: IdentityDirectory;
    now?: () => number;
    log?: (event: string, fields?: Record<string, unknown>) => void;
  }) {
    this.config = deps.config;
    this.directory = deps.directory;
    this.now = deps.now ?? Date.now;
    this.log = deps.log ?? (() => {});
  }

  get activeSessionCount(): number {
    let count = 0;
    for (const runtime of this.pairs.values()) {
      if (runtime.members.A && runtime.members.B) count += 1;
    }
    return count;
  }

  hasMembers(pairId: string): boolean {
    const runtime = this.pairs.get(pairId);
    return runtime !== undefined && Object.keys(runtime.members).length > 0;
  }

  sessionIdFor(pairId: string): string | null {
    return this.pairs.get(pairId)?.sessionId ?? null;
  }

  attach(input: AttachInput): AttachResult {
    const now = this.now();
    let runtime = this.pairs.get(input.pairId);
    if (runtime === undefined) {
      runtime = {
        pairId: input.pairId,
        sessionId: input.sessionId ?? uuidv4(),
        seq: 0,
        members: {},
        seen: new ReplayGuard({ ttlMs: this.config.sessionTimeoutMs * 2, maxEntries: 2048 }),
      };
      this.pairs.set(input.pairId, runtime);
    } else if (input.sessionId !== undefined) {
      runtime.sessionId = input.sessionId;
    }

    const previous = runtime.members[input.role];
    if (previous !== undefined && previous.socket !== input.socket) {
      this.safeClose(previous.socket, CLOSE_REPLACED, 'replaced_by_new_connection');
    }

    const member: Member = {
      role: input.role,
      deviceId: input.deviceId,
      socket: input.socket,
      joinedAt: now,
      lastSeen: input.lastSeen ?? now,
      windowStart: now,
      windowCount: 0,
      overLimit: 0,
      ...(input.olm ? { olm: input.olm } : {}),
    };
    runtime.members[input.role] = member;

    const peerRole = otherRole(input.role);
    const peer = runtime.members[peerRole] ?? null;
    const registered = this.directory.identityFor(peerRole);
    // The peer's one-time key changes per connection, so it comes from the live
    // member, not from stored metadata.
    const peerIdentity: PeerIdentity | null =
      registered === null
        ? null
        : {
            ...registered,
            ...(peer?.olm
              ? { olmIdentityKey: peer.olm.identityKey, olmOneTimeKey: peer.olm.oneTimeKey }
              : {}),
          };

    const welcome: WelcomeFrame = {
      v: 1,
      t: 'welcome',
      sessionId: runtime.sessionId,
      role: input.role,
      peerPresent: peer !== null,
      peer: peerIdentity,
      serverTime: now,
      heartbeatMs: this.config.heartbeatMs,
      sessionTimeoutMs: this.config.sessionTimeoutMs,
    };

    if (peer !== null && input.rehydrate !== true) {
      const selfIdentity = this.directory.identityFor(input.role);
      this.send(peer, {
        v: 1,
        t: 'peer',
        state: 'joined',
        ...(selfIdentity ? { deviceId: selfIdentity.deviceId, publicKey: selfIdentity.publicKey } : {}),
        ...(member.olm
          ? { olmIdentityKey: member.olm.identityKey, olmOneTimeKey: member.olm.oneTimeKey }
          : {}),
      });
      this.log('session.started', { pairId: input.pairId, sessionId: runtime.sessionId });
    }

    return { sessionId: runtime.sessionId, welcome };
  }

  /** Returns false when the pair/session is unknown (already terminated). */
  handleMessage(pairId: string, role: Role, raw: string): boolean {
    const runtime = this.pairs.get(pairId);
    if (runtime === undefined) return false;
    const member = runtime.members[role];
    if (member === undefined) return false;

    const now = this.now();
    member.lastSeen = now;

    const parsed = parseClientFrame(raw);
    if (!parsed.ok) {
      this.sendError(member, parsed.code, parsed.detail);
      return true;
    }

    if (!this.allowFrame(member, now)) {
      this.sendError(member, 'rate_limited', 'too many frames; slow down');
      if (member.overLimit > 3) this.safeClose(member.socket, 4008, 'rate_limited');
      return true;
    }

    const frame = parsed.frame;
    if (frame.t === 'ping') {
      this.send(member, { v: 1, t: 'pong', ts: frame.ts, serverTime: now });
      return true;
    }
    if (frame.t === 'bye') {
      const reason: EndReason = frame.reason === 'lock' ? 'peer_locked' : 'peer_left';
      this.log('session.bye', { pairId, sessionId: runtime.sessionId, by: role });
      this.endSession(pairId, reason, role);
      return true;
    }

    if (frame.t !== 'msg' && frame.t !== 'signal') {
      this.sendError(member, 'bad_frame', 'unexpected frame type after hello');
      return true;
    }

    const peer = runtime.members[otherRole(role)] ?? null;
    if (peer === null) {
      this.sendError(member, 'session_required', 'the other device is not connected; nothing is queued');
      return true;
    }
    if (!runtime.seen.check(`${role}:${frame.id}`, now)) {
      this.sendError(member, 'replay', 'duplicate frame id');
      return true;
    }

    runtime.seq += 1;
    const relay: ServerFrame = {
      v: 1,
      t: frame.t,
      id: frame.id,
      seq: runtime.seq,
      from: role,
      cipher: frame.cipher as CipherEnvelope,
    };
    this.send(peer, relay);
    return true;
  }

  detach(pairId: string, role: Role, reason: EndReason = 'peer_left'): void {
    const runtime = this.pairs.get(pairId);
    if (runtime === undefined) return;
    const member = runtime.members[role];
    if (member === undefined) return;
    delete runtime.members[role];
    if (runtime.members[otherRole(role)] !== undefined) {
      this.endSession(pairId, reason, role);
      return;
    }
    this.pairs.delete(pairId);
  }

  terminate(pairId: string, reason: EndReason): void {
    this.endSession(pairId, reason, null);
  }

  terminateAll(reason: EndReason): void {
    for (const pairId of [...this.pairs.keys()]) this.endSession(pairId, reason, null);
  }

  /** Close silent connections and end the sessions they belonged to. */
  sweep(now: number = this.now()): string[] {
    const ended: string[] = [];
    for (const [pairId, runtime] of [...this.pairs.entries()]) {
      let stale = false;
      for (const member of Object.values(runtime.members) as Member[]) {
        if (now - member.lastSeen > this.config.sessionTimeoutMs) {
          stale = true;
          this.safeClose(member.socket, CLOSE_SESSION_ENDED, 'timeout');
        }
      }
      if (stale) {
        this.log('session.timeout', { pairId, sessionId: runtime.sessionId });
        this.endSession(pairId, 'timeout', null);
        ended.push(pairId);
      }
    }
    return ended;
  }

  private endSession(pairId: string, reason: EndReason, except: Role | null): void {
    const runtime = this.pairs.get(pairId);
    if (runtime === undefined) return;
    for (const role of ['A', 'B'] as const) {
      const member = runtime.members[role];
      if (member === undefined) continue;
      if (member.role !== except) this.send(member, { v: 1, t: 'end', reason });
      this.safeClose(member.socket, CLOSE_SESSION_ENDED, reason);
    }
    this.pairs.delete(pairId);
  }

  private allowFrame(member: Member, now: number): boolean {
    if (now - member.windowStart >= 60_000) {
      member.windowStart = now;
      member.windowCount = 0;
    }
    member.windowCount += 1;
    if (member.windowCount <= this.config.ratePerMinute) {
      member.overLimit = 0;
      return true;
    }
    member.overLimit += 1;
    return false;
  }

  private sendError(member: Member, code: ErrorCode, detail: string): void {
    this.send(member, { v: 1, t: 'err', code, detail });
  }

  private send(member: Member, frame: ServerFrame): void {
    try {
      member.socket.send(encodeFrame(frame));
    } catch {
      // A dead socket is handled by the close path; never throw into the relay.
    }
  }

  private safeClose(socket: SocketLike, code: number, reason: string): void {
    try {
      socket.close(code, reason);
    } catch {
      // ignore
    }
  }

  /** Redacted runtime view for diagnostics and tests (no ciphertext, no ids). */
  debugState(): Record<string, unknown> {
    return {
      pairs: [...this.pairs.values()].map((runtime) => ({
        pairId: runtime.pairId,
        sessionId: runtime.sessionId,
        seq: runtime.seq,
        members: (Object.values(runtime.members) as Member[]).map((member) => ({
          role: member.role,
          deviceId: member.deviceId,
          joinedAt: member.joinedAt,
          lastSeen: member.lastSeen,
        })),
      })),
    };
  }
}
