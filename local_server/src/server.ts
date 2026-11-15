/**
 * SecretPlay local relay: Fastify HTTP surface + `ws` WebSocket endpoint.
 *
 * HTTP
 *   GET  /health                 liveness + slot/session summary (no secrets)
 *   GET  /v1/info                protocol + heartbeat + ICE configuration
 *   GET  /v1/pair/challenge     issue a 30-second one-use local pairing challenge
 *   POST /v1/pair/register     redeem an HMAC challenge proof and register a public device identity
 *   POST /v1/admin/invite        reprint the current invitation (admin token)
 *   POST /v1/admin/revoke        revoke a device slot (admin token)
 *   POST /v1/admin/reset         forget everything and re-pair (admin token)
 *   POST /v1/admin/shutdown      stop the relay (admin token)
 *
 * WebSocket
 *   /v1/ws     hello -> welcome, then msg/signal/ping/bye
 *
 * The relay is a blind pipe: it validates auth and frame shape, forwards
 * ciphertext, and never writes anything to disk.
 */

import Fastify, { type FastifyInstance } from 'fastify';
import { WebSocketServer, type WebSocket } from 'ws';
import type { IncomingMessage } from 'node:http';

import {
  MAX_FRAME_BYTES,
  b64u,
  canonicalJson,
  b64uDecode,
  isRecord,
  parseClientFrame,
  randomBytes,
  timingSafeEqual,
  utf8,
  ReplayGuard,
  sha256,
  hmacSha256,
  verifySignedHello,
  encodePairingQr,
  type PairingQrLocal,
} from '../../crypto_core/src/index.ts';
import { otherRole, type PeerIdentity, type Role } from '../../crypto_core/src/frames.ts';
import type { LocalServerConfig } from './config.ts';
import { listLanAddresses, pickPrimaryAddress } from './net.ts';
import { SessionHub, type SocketLike } from './session.ts';
import { PairStore, type InviteState } from './store.ts';

const SERVER_VERSION = '1.0.0';
const HELLO_TIMEOUT_MS = 5_000;
const REGISTER_LIMIT_PER_MINUTE = 10;

export interface LocalServerHooks {
  onInvite?: (invite: InviteState | null, qr: string | null) => void;
  onPairComplete?: () => void;
  onLog?: (event: string, fields?: Record<string, unknown>) => void;
}

export interface LocalServer {
  readonly app: FastifyInstance;
  readonly store: PairStore;
  readonly hub: SessionHub;
  readonly config: LocalServerConfig;
  readonly adminToken: string;
  listen(): Promise<{ host: string; port: number }>;
  close(): Promise<void>;
  httpOrigin(): string;
  wsUrl(): string;
  pairingQr(invite: InviteState): string;
  currentInvite(): InviteState | null;
  refreshInvite(): InviteState | null;
}

interface ConnectionState {
  authed: boolean;
  role: Role | null;
  deviceId: string | null;
  pairId: string | null;
  helloTimer: NodeJS.Timeout | null;
}

function sendJson(socket: WebSocket, frame: unknown): void {
  try {
    socket.send(JSON.stringify(frame));
  } catch {
    // closing socket: ignore
  }
}

export async function createLocalServer(
  config: LocalServerConfig,
  hooks: LocalServerHooks = {},
): Promise<LocalServer> {
  const log = hooks.onLog ?? (() => {});
  const startedAt = Date.now();

  const adminToken = config.adminToken.length >= 16 ? config.adminToken : b64u(randomBytes(18));
  const helloNonces = new ReplayGuard({ ttlMs: 120_000, maxEntries: 512 });
  const store = new PairStore({ inviteTtlMs: config.inviteTtlMs });

  const directory = {
    identityFor(role: Role): PeerIdentity | null {
      const device = store.getDevice(role);
      if (!device) return null;
      return {
        deviceId: device.deviceId,
        publicKey: b64u(device.publicKey),
        ...(device.olmKey ? { olmIdentityKey: device.olmKey } : {}),
      };
    },
    isRevoked(deviceId: string): boolean {
      return store.isRevoked(deviceId);
    },
  };

  const hub = new SessionHub({
    config: {
      heartbeatMs: config.heartbeatMs,
      sessionTimeoutMs: config.sessionTimeoutMs,
      ratePerMinute: config.ratePerMinute,
    },
    directory,
    log,
  });

  const app = Fastify({ logger: false, bodyLimit: 8 * 1024, disableRequestLogging: true });
  let boundPort = config.port;

  const addresses = listLanAddresses();
  const primary = pickPrimaryAddress(addresses);
  const advertisedHost = primary?.address ?? '127.0.0.1';

  const httpOrigin = (): string => `http://${advertisedHost}:${boundPort}`;
  const wsUrl = (): string => `ws://${advertisedHost}:${boundPort}/v1/ws`;

  const pairingQr = (invite: InviteState): string =>
    encodePairingQr({
      v: 1,
      proto: 'sp1',
      mode: 'local',
      wsUrl: wsUrl(),
      httpUrl: httpOrigin(),
      pairId: store.pairId,
      invite: invite.token,
      expiresAt: invite.expiresAt,
    });

  const announceInvite = (): InviteState | null => {
    const invite = store.ensureInvite();
    hooks.onInvite?.(invite, invite ? pairingQr(invite) : null);
    return invite;
  };

  const checkAdmin = (provided: unknown): boolean => {
    if (typeof provided !== 'string') return false;
    const a = utf8(provided);
    const b = utf8(adminToken);
    return a.length === b.length && timingSafeEqual(a, b);
  };

  const registerAttempts = new Map<string, { windowStart: number; count: number }>();
  const pairingChallenges = new Map<string, { pairId: string; expiresAt: number }>();
  const PAIRING_CHALLENGE_TTL_MS = 30_000;
  const allowRegister = (ip: string): boolean => {
    const now = Date.now();
    const entry = registerAttempts.get(ip);
    if (!entry || now - entry.windowStart >= 60_000) {
      registerAttempts.set(ip, { windowStart: now, count: 1 });
      return true;
    }
    entry.count += 1;
    return entry.count <= REGISTER_LIMIT_PER_MINUTE;
  };

  app.get('/health', async () => ({
    status: 'ok',
    mode: 'local',
    protocol: 'sp1',
    serverVersion: SERVER_VERSION,
    uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
    pairId: store.pairId,
    slots: { filled: store.slotsFilled, complete: store.isComplete },
    session: { active: hub.activeSessionCount > 0 },
    inviteActive: store.activeInvite !== null,
  }));

  app.get('/v1/info', async () => ({
    protocol: 'sp1',
    mode: 'local',
    serverVersion: SERVER_VERSION,
    pairId: store.pairId,
    heartbeatMs: config.heartbeatMs,
    sessionTimeoutMs: config.sessionTimeoutMs,
    // Local mode never depends on a public STUN/TURN server by default.
    iceServers: config.extraIceServers.map((urls) => ({ urls })),
  }));

  app.get('/v1/pair/challenge', async (request, reply) => {
    const query = request.query as Record<string, unknown>;
    const pairId = query.pairId;
    if (typeof pairId !== 'string' || pairId !== store.pairId) {
      return reply.code(404).send({ error: 'pair_unknown' });
    }
    if (!store.activeInvite) return reply.code(409).send({ error: 'pair_full' });
    if (!allowRegister(request.ip)) return reply.code(429).send({ error: 'rate_limited' });

    const now = Date.now();
    for (const [key, challenge] of pairingChallenges) {
      if (challenge.expiresAt <= now) pairingChallenges.delete(key);
    }
    while (pairingChallenges.size >= 1024) {
      const oldest = pairingChallenges.keys().next();
      if (oldest.done) break;
      pairingChallenges.delete(oldest.value);
    }
    const challenge = b64u(randomBytes(24));
    const expiresAt = now + PAIRING_CHALLENGE_TTL_MS;
    pairingChallenges.set(challenge, { pairId, expiresAt });
    return reply.send({ pairId, challenge, expiresAt });
  });

  app.post('/v1/pair/register', async (request, reply) => {
    if (!allowRegister(request.ip)) {
      return reply.code(429).send({ error: 'rate_limited' });
    }
    const body = request.body;
    if (!isRecord(body)) return reply.code(400).send({ error: 'bad_request' });

    const challengeValue = body.challenge;
    const proofValue = body.proof;
    const deviceId = body.deviceId;
    const publicKey = body.publicKey;
    const olmKey = body.olmKey;
    if (typeof challengeValue !== 'string' || typeof proofValue !== 'string' ||
        typeof deviceId !== 'string' || typeof publicKey !== 'string' ||
        typeof olmKey !== 'string') {
      return reply.code(400).send({ error: 'bad_request' });
    }

    // The QR invitation is never sent over the cleartext LAN. The client uses
    // it as an HMAC key for this one-use challenge proof; the request therefore
    // reveals neither the invitation nor a reusable bearer credential.
    const challenge = pairingChallenges.get(challengeValue);
    pairingChallenges.delete(challengeValue); // one-shot, even on failure
    if (!challenge || challenge.expiresAt <= Date.now() || challenge.pairId !== store.pairId) {
      return reply.code(403).send({ error: 'unauthorized', detail: 'pairing challenge expired or already used' });
    }
    const invite = store.activeInvite;
    if (!invite) return reply.code(409).send({ error: 'pair_full' });

    let keyBytes: Uint8Array;
    let olmBytes: Uint8Array;
    let proofBytes: Uint8Array;
    try {
      keyBytes = b64uDecode(publicKey);
      olmBytes = b64uDecode(olmKey);
      proofBytes = b64uDecode(proofValue);
    } catch {
      return reply.code(400).send({ error: 'bad_request', detail: 'public keys and proof must be base64url' });
    }
    if (keyBytes.length !== 32 || olmBytes.length !== 32 || proofBytes.length !== 32) {
      return reply.code(400).send({ error: 'bad_request', detail: 'public keys and proof must be 32 bytes' });
    }

    const signedData = canonicalJson({
      domain: 'secretplay.local-pairing.v1',
      pairId: store.pairId,
      challenge: challengeValue,
      deviceId,
      publicKey,
      olmKey,
    });
    const proofKey = sha256(`secretplay.invite.v1|${invite.token}`);
    const expectedProof = hmacSha256(proofKey, signedData);
    if (!timingSafeEqual(expectedProof, proofBytes)) {
      log('pair.register_rejected', { code: 'bad_pairing_proof' });
      return reply.code(403).send({ error: 'unauthorized', detail: 'pairing proof is invalid' });
    }

    const result = store.register({
      inviteToken: invite.token,
      deviceId,
      publicKey: keyBytes,
      olmKey,
    });
    if (!result.ok) {
      log('pair.register_rejected', { code: result.code });
      const status = result.code === 'pair_full' ? 409 : 403;
      return reply.code(status).send({ error: result.code, detail: result.detail });
    }

    // Invalidate outstanding challenges against the consumed invitation.
    for (const [key, value] of pairingChallenges) {
      if (value.pairId === store.pairId) pairingChallenges.delete(key);
    }
    log('pair.registered', { role: result.device.role, reissued: result.reissued });
    if (store.isComplete) {
      hooks.onPairComplete?.();
      hooks.onInvite?.(null, null);
    } else {
      announceInvite();
    }

    const peerIdentity = directory.identityFor(otherRole(result.device.role));
    return reply.send({
      pairId: store.pairId,
      role: result.device.role,
      deviceId: result.device.deviceId,
      wsUrl: wsUrl(),
      peer: peerIdentity,
    });
  });

  app.post('/v1/admin/invite', async (request, reply) => {
    if (!checkAdmin(request.headers['x-admin-token'])) return reply.code(401).send({ error: 'unauthorized' });
    const invite = announceInvite();
    if (!invite) return reply.code(409).send({ error: 'pair_complete' });
    return reply.send({ pairId: store.pairId, invite: invite.token, expiresAt: invite.expiresAt, qr: pairingQr(invite) });
  });

  app.post('/v1/admin/revoke', async (request, reply) => {
    if (!checkAdmin(request.headers['x-admin-token'])) return reply.code(401).send({ error: 'unauthorized' });
    const body = request.body;
    if (!isRecord(body) || (body.role !== 'A' && body.role !== 'B')) {
      return reply.code(400).send({ error: 'bad_request' });
    }
    const revoked = store.revoke(body.role);
    if (!revoked) return reply.code(404).send({ error: 'not_found' });
    hub.terminate(store.pairId, 'revoked');
    log('pair.revoked', { role: revoked.role });
    announceInvite();
    return reply.send({ revoked: { role: revoked.role, deviceId: revoked.deviceId } });
  });

  app.post('/v1/admin/reset', async (request, reply) => {
    if (!checkAdmin(request.headers['x-admin-token'])) return reply.code(401).send({ error: 'unauthorized' });
    hub.terminate(store.pairId, 'replaced');
    store.reset();
    log('pair.reset');
    const invite = announceInvite();
    return reply.send({ pairId: store.pairId, invite: invite?.token ?? null });
  });

  app.post('/v1/admin/shutdown', async (request, reply) => {
    if (!checkAdmin(request.headers['x-admin-token'])) return reply.code(401).send({ error: 'unauthorized' });
    log('server.shutdown_requested');
    setTimeout(() => {
      void close();
    }, 50).unref?.();
    return reply.send({ stopping: true });
  });

  // ---------------------------------------------------------------------
  // WebSocket relay
  // ---------------------------------------------------------------------
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES });

  const authenticate = (
    socket: WebSocket,
    state: ConnectionState,
    raw: string,
  ): boolean => {
    const parsed = parseClientFrame(raw);
    if (!parsed.ok || parsed.frame.t !== 'hello') {
      sendJson(socket, { v: 1, t: 'err', code: 'bad_frame', detail: 'expected a hello frame first' });
      socket.close(4002, 'hello_required');
      return false;
    }
    const hello = parsed.frame;
    if (hello.auth.kind !== 'signed') {
      // A bearer token would be sniffable on a cleartext LAN socket and could be
      // replayed from another machine, so local mode proves key possession too.
      sendJson(socket, {
        v: 1,
        t: 'err',
        code: 'unauthorized',
        detail: 'local mode requires a signed hello',
      });
      socket.close(4003, 'unauthorized');
      return false;
    }
    if (hello.pairId !== store.pairId) {
      sendJson(socket, { v: 1, t: 'err', code: 'pair_unknown', detail: 'this relay serves a different pair' });
      socket.close(4004, 'pair_unknown');
      return false;
    }
    if (store.isRevoked(hello.deviceId)) {
      sendJson(socket, { v: 1, t: 'err', code: 'device_revoked', detail: 'this device was revoked' });
      socket.close(4003, 'unauthorized');
      return false;
    }
    const device = store.getDevice(hello.role);
    if (!device || device.deviceId !== hello.deviceId) {
      sendJson(socket, { v: 1, t: 'err', code: 'unauthorized', detail: 'device is not authorised' });
      socket.close(4003, 'unauthorized');
      return false;
    }
    if (store.isRevoked(device.deviceId)) {
      sendJson(socket, { v: 1, t: 'err', code: 'device_revoked', detail: 'this device was revoked' });
      socket.close(4003, 'unauthorized');
      return false;
    }

    // Signed hellos must carry Olm bootstrap keys. The protocol parser enforces
    // this at runtime, but TypeScript cannot narrow the nested union member
    // through `hello.auth.kind`, so assert the invariant explicitly here too.
    const olm = hello.olm;
    if (!olm) {
      sendJson(socket, { v: 1, t: 'err', code: 'unauthorized', detail: 'signed hello is missing Olm bootstrap keys' });
      socket.close(4003, 'unauthorized');
      return false;
    }

    // The store keeps the key as raw bytes; no decoding happens here.
    const publicKey = device.publicKey;
    if (!(publicKey instanceof Uint8Array) || publicKey.length !== 32) {
      sendJson(socket, { v: 1, t: 'err', code: 'unauthorized', detail: 'registered key is malformed' });
      socket.close(4003, 'unauthorized');
      return false;
    }
    // The Ed25519 identity is registered at pairing time. Its Curve25519
    // identity must remain stable across sessions; only the one-time pre-key
    // is expected to rotate. This prevents a valid device signature from
    // silently substituting a different long-term Olm identity.
    if (!device.olmKey || olm.identityKey !== device.olmKey) {
      sendJson(socket, { v: 1, t: 'err', code: 'unauthorized', detail: 'Olm identity key does not match the registered device identity' });
      socket.close(4003, 'unauthorized');
      return false;
    }

    const verified = verifySignedHello({
      publicKey,
      pairId: hello.pairId,
      deviceId: hello.deviceId,
      role: hello.role,
      auth: hello.auth,
      olm,
      now: Date.now(),
    });
    if (!verified.ok) {
      sendJson(socket, { v: 1, t: 'err', code: 'unauthorized', detail: verified.detail });
      socket.close(4003, 'unauthorized');
      return false;
    }
    if (!helloNonces.check(`hello:${hello.deviceId}:${hello.auth.nonce}`, Date.now())) {
      sendJson(socket, { v: 1, t: 'err', code: 'replay', detail: 'hello nonce was already used' });
      socket.close(4003, 'replay');
      return false;
    }

    state.authed = true;
    state.role = hello.role;
    state.deviceId = hello.deviceId;
    state.pairId = hello.pairId;
    if (state.helloTimer) {
      clearTimeout(state.helloTimer);
      state.helloTimer = null;
    }

    const { welcome } = hub.attach({
      pairId: hello.pairId,
      role: hello.role,
      deviceId: hello.deviceId,
      socket: socket as unknown as SocketLike,
      olm,
    });
    sendJson(socket, welcome);
    return true;
  };

  wss.on('connection', (socket: WebSocket, _request: IncomingMessage) => {
    const helloTimer: NodeJS.Timeout = setTimeout(() => {
      if (!state.authed) socket.close(4002, 'hello_timeout');
    }, HELLO_TIMEOUT_MS);
    helloTimer.unref?.();
    const state: ConnectionState = {
      authed: false,
      role: null,
      deviceId: null,
      pairId: null,
      helloTimer,
    };

    socket.on('message', (data, isBinary) => {
      if (isBinary) {
        sendJson(socket, { v: 1, t: 'err', code: 'bad_frame', detail: 'binary frames are not supported' });
        return;
      }
      const raw = data.toString();
      if (state.authed && state.pairId && state.role) {
        hub.handleMessage(state.pairId, state.role, raw);
        return;
      }
      authenticate(socket, state, raw);
    });

    socket.on('close', () => {
      if (state.helloTimer) clearTimeout(state.helloTimer);
      if (state.authed && state.pairId && state.role) {
        hub.detach(state.pairId, state.role, 'peer_left');
        log('session.detached', { role: state.role });
      }
    });

    socket.on('error', () => {
      // Closing is handled by the close event.
    });
  });

  app.server.on('upgrade', (request, socket, head) => {
    let pathname = '';
    try {
      pathname = new URL(request.url ?? '/', 'http://localhost').pathname;
    } catch {
      socket.destroy();
      return;
    }
    if (pathname !== '/v1/ws') {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request);
    });
  });

  const sweepTimer = setInterval(() => {
    hub.sweep();
  }, config.sweepIntervalMs);
  sweepTimer.unref?.();

  const listen = async (): Promise<{ host: string; port: number }> => {
    await app.listen({ port: config.port, host: config.host });
    const address = app.server.address();
    if (address && typeof address === 'object') boundPort = address.port;
    announceInvite();
    log('server.start', { host: config.host, port: boundPort, interfaces: addresses.length });
    return { host: config.host, port: boundPort };
  };

  let closing = false;
  const close = async (): Promise<void> => {
    if (closing) return;
    closing = true;
    clearInterval(sweepTimer);
    hub.terminateAll('server_shutdown');
    await new Promise<void>((resolve) => wss.close(() => resolve()));
    await app.close();
    log('server.stop');
  };

  return {
    app,
    store,
    hub,
    config,
    adminToken,
    listen,
    close,
    httpOrigin,
    wsUrl,
    pairingQr,
    currentInvite: () => store.activeInvite,
    refreshInvite: announceInvite,
  };
}
