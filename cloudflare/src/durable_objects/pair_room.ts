/**
 * PairRoom — one Durable Object per pair.
 *
 * Responsibilities, and nothing else:
 *  - store minimal identity/invitation/revocation metadata in SQLite;
 *  - authenticate the two devices (Ed25519 signed hello);
 *  - relay opaque ciphertext between them while both are connected;
 *  - terminate the session when either side leaves, locks, or goes silent;
 *  - keep WebSockets through hibernation and reload state from attachments.
 *
 * It never persists ciphertext, never queues messages, and has no table that
 * could hold a conversation (enforced by `assertMetadataOnlySchema`).
 */

import {
  MAX_FRAME_BYTES,
  b64u,
  b64uDecode,
  ReplayGuard,
  encodeFrame,
  parseClientFrame,
  verifySignedHello,
  verifyRevokeRequest,
  createInvite,
  deviceIdFromPublicKey,
  isRecord,
  type SignedRevokeRequest,
  type Role,
  type OlmKeys,
} from '../../../crypto_core/src/index.ts';
import { RoomMachine } from '../../../crypto_core/src/room.ts';
import { PairMetadata, type DeviceRow, type SqlStorageLike } from '../metadata.ts';
import { planRegistration } from '../protocol_rules.ts';
import type { Env } from '../env.ts';
import { heartbeatConfig } from '../env.ts';

interface SocketAttachment {
  kind: 'pending' | 'authed';
  pairId: string;
  role?: Role;
  deviceId?: string;
  sessionId?: string;
  lastSeen?: number;
  // Only public Olm bootstrap material is attached. Never persist ratchet or
  // decryption keys; this is required to restore live peers after DO hibernation.
  olm?: OlmKeys;
}

const INVITE_TTL_MS = 10 * 60 * 1000;
const HELLO_GRACE_MS = 10_000;

function isOlmKey(value: string): boolean {
  if (value.length === 0 || value.length > 64) return false;
  try {
    return b64uDecode(value).length === 32;
  } catch {
    return false;
  }
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });
}

function attachmentOf(ws: WebSocket): SocketAttachment {
  const raw = ws.deserializeAttachment();
  if (!isRecord(raw) || typeof raw.pairId !== 'string') {
    return { kind: 'pending', pairId: '' };
  }
  return raw as unknown as SocketAttachment;
}

export class PairRoom {
  private readonly ctx: DurableObjectState;
  private readonly env: Env;
  private readonly meta: PairMetadata;
  private readonly hub: RoomMachine;
  private readonly config: ReturnType<typeof heartbeatConfig>;
  private readonly helloNonces = new ReplayGuard({ ttlMs: 5 * 60 * 1000, maxEntries: 1024 });
  private pairId = '';
  private restored = false;

  constructor(ctx: DurableObjectState, env: Env) {
    this.ctx = ctx;
    this.env = env;
    this.config = heartbeatConfig(env);
    this.meta = new PairMetadata(ctx.storage.sql as unknown as SqlStorageLike);
    this.hub = new RoomMachine({
      config: this.config,
      directory: {
        identityFor: (role: Role) => this.identityFor(role),
        isRevoked: (deviceId: string) => (this.pairId ? this.meta.isRevoked(this.pairId, deviceId) : false),
      },
    });
    ctx.blockConcurrencyWhile(async () => {
      this.meta.migrate();
    });
  }

  private identityFor(role: Role): { deviceId: string; publicKey: string; olmIdentityKey?: string } | null {
    if (this.pairId === '') return null;
    const device = this.meta.deviceFor(this.pairId, role);
    if (device === null) return null;
    return {
      deviceId: device.deviceId,
      publicKey: device.publicKey,
      ...(device.olmKey ? { olmIdentityKey: device.olmKey } : {}),
    };
  }

  /** Rebuild in-memory session state from hibernated sockets (once per wake). */
  private restore(): void {
    if (this.restored) return;
    this.restored = true;
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = attachmentOf(ws);
      if (attachment.kind !== 'authed' || !attachment.role || !attachment.deviceId) continue;
      this.pairId = attachment.pairId;
      this.hub.attach({
        pairId: attachment.pairId,
        role: attachment.role,
        deviceId: attachment.deviceId,
        socket: ws as unknown as { send(data: string): void; close(code?: number, reason?: string): void },
        ...(attachment.sessionId ? { sessionId: attachment.sessionId } : {}),
        ...(attachment.lastSeen ? { lastSeen: attachment.lastSeen } : {}),
        ...(attachment.olm ? { olm: attachment.olm } : {}),
        rehydrate: true,
      });
    }
  }

  private async ensureAlarm(): Promise<void> {
    if (!this.hub.hasMembers(this.pairId)) return;
    const current = await this.ctx.storage.getAlarm();
    if (current === null) {
      await this.ctx.storage.setAlarm(Date.now() + this.config.sessionTimeoutMs + 1000);
    }
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    this.restore();
    const pairFromQuery = url.searchParams.get('pair');

    if (url.pathname === '/ws') {
      if (pairFromQuery === null) return json({ error: 'bad_request', detail: 'pair is required' }, 400);
      this.pairId = pairFromQuery;
      if (!this.meta.hasPair(this.pairId)) return json({ error: 'pair_unknown' }, 404);

      const pair = new WebSocketPair();
      // WebSocketPair is always a 2-tuple at runtime.
      const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
      this.ctx.acceptWebSocket(server);
      server.serializeAttachment({ kind: 'pending', pairId: this.pairId } satisfies SocketAttachment);
      await this.ctx.storage.setAlarm(Date.now() + HELLO_GRACE_MS);
      return new Response(null, { status: 101, webSocket: client });
    }

    if (url.pathname === '/create' && request.method === 'POST') return this.handleCreate(request);
    if (url.pathname === '/register' && request.method === 'POST') return this.handleRegister(request);
    if (url.pathname === '/revoke' && request.method === 'POST') return this.handleRevoke(request);
    if (url.pathname === '/state' && request.method === 'GET') {
      const pairId = pairFromQuery ?? this.pairId;
      if (!pairId) return json({ error: 'bad_request' }, 400);
      this.pairId = pairId;
      return json({ pair: this.meta.snapshot(pairId), sessions: this.hub.debugState() });
    }
    return json({ error: 'not_found' }, 404);
  }

  private async readJson(request: Request): Promise<Record<string, unknown> | null> {
    try {
      const body = await request.json();
      return isRecord(body) ? body : null;
    } catch {
      return null;
    }
  }

  private async handleCreate(request: Request): Promise<Response> {
    const body = await this.readJson(request);
    if (!body) return json({ error: 'bad_request' }, 400);
    const { pairId, deviceId, publicKey, inviteToken, olmKey } = body;
    if (
      typeof pairId !== 'string' ||
      typeof deviceId !== 'string' ||
      typeof publicKey !== 'string' ||
      typeof inviteToken !== 'string' ||
      typeof olmKey !== 'string'
    ) {
      return json({ error: 'bad_request' }, 400);
    }
    if (!isOlmKey(olmKey)) {
      return json({ error: 'bad_request', detail: 'olmKey must be a 32-byte base64url Curve25519 identity key' }, 400);
    }

    let keyBytes: Uint8Array;
    try {
      keyBytes = b64uDecode(publicKey);
    } catch {
      return json({ error: 'bad_request', detail: 'publicKey must be base64url' }, 400);
    }
    if (keyBytes.length !== 32 || deviceIdFromPublicKey(keyBytes) !== deviceId) {
      return json({ error: 'unauthorized', detail: 'deviceId does not match the supplied public key' }, 403);
    }

    this.pairId = pairId;
    if (this.meta.hasPair(pairId)) {
      return json({ error: 'pair_full', detail: 'this pair already exists' }, 409);
    }
    this.meta.ensurePair(pairId);
    this.meta.putDevice(pairId, 'A', deviceId, publicKey, olmKey);
    const invite = this.meta.createInvite(pairId, inviteToken, INVITE_TTL_MS);
    return json({ pairId, role: 'A', inviteExpiresAt: invite.expiresAt });
  }

  private async handleRegister(request: Request): Promise<Response> {
    const body = await this.readJson(request);
    if (!body) return json({ error: 'bad_request' }, 400);
    const { pairId, invite, deviceId, publicKey, olmKey } = body;
    if (
      typeof pairId !== 'string' ||
      typeof invite !== 'string' ||
      typeof deviceId !== 'string' ||
      typeof publicKey !== 'string' ||
      typeof olmKey !== 'string'
    ) {
      return json({ error: 'bad_request' }, 400);
    }
    if (!isOlmKey(olmKey)) {
      return json({ error: 'bad_request', detail: 'olmKey must be a 32-byte base64url Curve25519 identity key' }, 400);
    }

    this.pairId = pairId;
    if (!this.meta.hasPair(pairId)) return json({ error: 'pair_unknown' }, 404);
    if (this.meta.isRevoked(pairId, deviceId)) {
      return json({ error: 'device_revoked', detail: 'this device was revoked' }, 403);
    }

    let keyBytes: Uint8Array;
    try {
      keyBytes = b64uDecode(publicKey);
    } catch {
      return json({ error: 'bad_request', detail: 'publicKey must be base64url' }, 400);
    }

    const existing = this.meta.deviceById(pairId, deviceId);
    const plan = planRegistration({
      devicesStored: this.meta.countDevices(pairId),
      claimedDeviceId: deviceId,
      derivedDeviceId: deviceIdFromPublicKey(keyBytes),
      publicKeyBytes: keyBytes.length,
      alreadyRegisteredRole: existing?.role ?? null,
      inviteUsable: this.meta.activeInvite(pairId) !== null,
      targetSlotFree: this.meta.countDevices(pairId) < 2,
    });

    if (!plan.ok) {
      const status = plan.code === 'pair_full' ? 409 : 403;
      return json({ error: plan.code, detail: plan.detail }, status);
    }
    // A device re-registering while its slot is live would swap a victim's key
    // without the peer noticing. Refuse it: the peer must verify a new identity
    // only when the old device is genuinely gone (disconnected or revoked).
    const slotBusy = this.ctx.getWebSockets().some((ws) => {
      const held = attachmentOf(ws);
      return held.kind === 'authed' && held.pairId === pairId && held.role === plan.role;
    });
    if (slotBusy) {
      return json(
        { error: 'device_connected', detail: 'that slot is connected; disconnect it before re-registering' },
        409,
      );
    }

    if (!this.meta.consumeInvite(pairId, invite)) {
      return json({ error: 'unauthorized', detail: 'pairing invitation is invalid, expired or already used' }, 403);
    }

    this.meta.putDevice(pairId, plan.role, deviceId, publicKey, olmKey);
    const peerRole: Role = plan.role === 'A' ? 'B' : 'A';
    const peer: DeviceRow | null = this.meta.deviceFor(pairId, peerRole);
    return json({
      pairId,
      role: plan.role,
      reissued: plan.reissued,
      peer: peer
        ? {
            deviceId: peer.deviceId,
            publicKey: peer.publicKey,
            ...(peer.olmKey ? { olmIdentityKey: peer.olmKey } : {}),
          }
        : null,
    });
  }

  private async handleRevoke(request: Request): Promise<Response> {
    const body = await this.readJson(request);
    if (!body || !isRecord(body.request)) return json({ error: 'bad_request' }, 400);
    const pairId = body.pairId;
    if (typeof pairId !== 'string') return json({ error: 'bad_request' }, 400);
    this.pairId = pairId;

    const signed = body.request as unknown as SignedRevokeRequest;
    if (
      typeof signed.requesterRole !== 'string' ||
      typeof signed.requesterDeviceId !== 'string' ||
      typeof signed.targetRole !== 'string' ||
      typeof signed.ts !== 'number' ||
      typeof signed.nonce !== 'string' ||
      typeof signed.sig !== 'string'
    ) {
      return json({ error: 'bad_request' }, 400);
    }

    const requester = this.meta.deviceFor(pairId, signed.requesterRole as Role);
    if (!requester || requester.deviceId !== signed.requesterDeviceId) {
      return json({ error: 'unauthorized', detail: 'requester is not an authorised device' }, 403);
    }
    if (!this.helloNonces.check(`revoke:${signed.nonce}`, Date.now())) {
      return json({ error: 'replay' }, 409);
    }
    const verified = verifyRevokeRequest({
      pairId,
      request: signed,
      publicKey: b64uDecode(requester.publicKey),
      now: Date.now(),
    });
    if (!verified.ok) return json({ error: 'unauthorized', detail: verified.detail }, 403);

    const revoked = this.meta.revokeDevice(pairId, signed.targetRole as Role);
    if (!revoked) return json({ error: 'not_found' }, 404);
    this.hub.terminate(pairId, 'revoked');

    const invite = createInvite();
    const stored = this.meta.createInvite(pairId, invite.token, INVITE_TTL_MS);
    return json({
      revoked: { role: revoked.role, deviceId: revoked.deviceId },
      invite: invite.token,
      inviteExpiresAt: stored.expiresAt,
    });
  }

  // ------------------------------------------------------------------
  // Hibernatable WebSocket handlers
  // ------------------------------------------------------------------

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    this.restore();
    if (typeof message !== 'string') {
      ws.send(encodeFrame({ v: 1, t: 'err', code: 'bad_frame', detail: 'binary frames are not supported' }));
      return;
    }

    const attachment = attachmentOf(ws);
    if (attachment.kind === 'pending') {
      this.handleHello(ws, attachment, message);
      return;
    }

    if (!attachment.role || !attachment.deviceId) return;
    const now = Date.now();
    ws.serializeAttachment({ ...attachment, lastSeen: now } satisfies SocketAttachment);
    this.hub.handleMessage(attachment.pairId, attachment.role, message);
    await this.ensureAlarm();
  }

  private handleHello(ws: WebSocket, attachment: SocketAttachment, message: string): void {
    const parsed = parseClientFrame(message);
    if (!parsed.ok || parsed.frame.t !== 'hello') {
      ws.send(encodeFrame({ v: 1, t: 'err', code: 'bad_frame', detail: 'expected a signed hello first' }));
      ws.close(4002, 'hello_required');
      return;
    }
    const hello = parsed.frame;
    if (hello.auth.kind !== 'signed') {
      ws.send(encodeFrame({ v: 1, t: 'err', code: 'unauthorized', detail: 'cloud mode requires a signed hello' }));
      ws.close(4003, 'unauthorized');
      return;
    }
    if (hello.pairId !== attachment.pairId) {
      ws.send(encodeFrame({ v: 1, t: 'err', code: 'unauthorized', detail: 'hello pair does not match the room' }));
      ws.close(4003, 'unauthorized');
      return;
    }

    // Signed hellos must carry Olm bootstrap keys. Keep an explicit runtime
    // guard because TypeScript does not narrow this nested union property.
    const olm = hello.olm;
    if (!olm) {
      ws.send(encodeFrame({ v: 1, t: 'err', code: 'unauthorized', detail: 'signed hello is missing Olm bootstrap keys' }));
      ws.close(4003, 'unauthorized');
      return;
    }

    const device = this.meta.deviceFor(hello.pairId, hello.role);
    if (!device || device.deviceId !== hello.deviceId || this.meta.isRevoked(hello.pairId, hello.deviceId)) {
      ws.send(encodeFrame({ v: 1, t: 'err', code: 'unauthorized', detail: 'device is not authorised' }));
      ws.close(4003, 'unauthorized');
      return;
    }

    // The registered Curve25519 identity is long-lived; only the signed
    // one-time pre-key may rotate per session. Reject identity substitution.
    if (!device.olmKey || olm.identityKey !== device.olmKey) {
      ws.send(encodeFrame({ v: 1, t: 'err', code: 'unauthorized', detail: 'Olm identity key does not match the registered device identity' }));
      ws.close(4003, 'unauthorized');
      return;
    }

    const now = Date.now();
    const verified = verifySignedHello({
      publicKey: b64uDecode(device.publicKey),
      pairId: hello.pairId,
      deviceId: hello.deviceId,
      role: hello.role,
      auth: hello.auth,
      olm,
      now,
    });
    if (!verified.ok) {
      ws.send(encodeFrame({ v: 1, t: 'err', code: verified.code, detail: verified.detail }));
      ws.close(4003, 'unauthorized');
      return;
    }
    if (!this.helloNonces.check(`hello:${hello.deviceId}:${hello.auth.nonce}`, now)) {
      ws.send(encodeFrame({ v: 1, t: 'err', code: 'replay', detail: 'hello nonce was already used' }));
      ws.close(4003, 'replay');
      return;
    }

    this.pairId = hello.pairId;
    const { sessionId, welcome } = this.hub.attach({
      pairId: hello.pairId,
      role: hello.role,
      deviceId: hello.deviceId,
      socket: ws as unknown as { send(data: string): void; close(code?: number, reason?: string): void },
      olm,
    });
    ws.serializeAttachment({
      kind: 'authed',
      pairId: hello.pairId,
      role: hello.role,
      deviceId: hello.deviceId,
      sessionId,
      lastSeen: now,
      // Preserve only the public session bootstrap keys across hibernation.
      olm,
    } satisfies SocketAttachment);
    ws.send(encodeFrame(welcome));
    void this.ensureAlarm();
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string, _wasClean: boolean): Promise<void> {
    const attachment = attachmentOf(ws);
    if (attachment.kind === 'authed' && attachment.role) {
      this.restore();
      this.hub.detach(attachment.pairId, attachment.role, 'peer_left');
      if (!this.hub.hasMembers(attachment.pairId)) await this.ctx.storage.deleteAlarm();
    }
    try {
      ws.close(code, reason);
    } catch {
      // already closed
    }
  }

  async webSocketError(ws: WebSocket, _error: unknown): Promise<void> {
    const attachment = attachmentOf(ws);
    if (attachment.kind === 'authed' && attachment.role) {
      this.hub.detach(attachment.pairId, attachment.role, 'protocol_error');
    }
  }

  async alarm(): Promise<void> {
    this.restore();
    const now = Date.now();
    // Unauthenticated sockets that never said hello are dropped here.
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = attachmentOf(ws);
      if (attachment.kind === 'pending') {
        try {
          ws.close(4002, 'hello_timeout');
        } catch {
          // ignore
        }
      }
    }
    this.hub.sweep(now);
    if (this.hub.hasMembers(this.pairId)) {
      await this.ctx.storage.setAlarm(now + this.config.sessionTimeoutMs + 1000);
    } else {
      await this.ctx.storage.deleteAlarm();
    }
  }
}
