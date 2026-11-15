/**
 * SecretPlay Cloudflare Worker — the public edge.
 *
 *   GET  /health                 liveness (no secrets)
 *   GET  /v1/info                protocol constants + ICE servers
 *   POST /v1/pair/create         device A creates the pair, returns an invite + QR
 *   POST /v1/pair/register       device B redeems the invitation
 *   POST /v1/pair/revoke         signed revocation from an authorised device
 *   GET  /v1/ws?pair=<id>        WebSocket, proxied to the pair's Durable Object
 *
 * The Worker never sees plaintext: message and signalling frames are opaque
 * Olm ciphertext that only the two phones can open.
 */

import {
  b64uDecode,
  createInvite,
  encodePairingQr,
  isRecord,
  newPairId,
  deviceIdFromPublicKey,
} from '../../crypto_core/src/index.ts';
import { heartbeatConfig, PAIR_ID_PATTERN, type Env } from './env.ts';
import { resolveIceServers, turnEnabled } from './turn.ts';

// Durable Object classes must be exported from the Worker entrypoint.
export { PairRoom } from './durable_objects/pair_room.ts';

const SERVER_VERSION = '1.0.0';
const CREATE_LIMIT_PER_MINUTE = 20;

interface AttemptWindow {
  windowStart: number;
  count: number;
}

const attempts = new Map<string, AttemptWindow>();

function allowAttempt(key: string, limit: number, now = Date.now()): boolean {
  const existing = attempts.get(key);
  if (!existing || now - existing.windowStart >= 60_000) {
    attempts.set(key, { windowStart: now, count: 1 });
    return true;
  }
  existing.count += 1;
  return existing.count <= limit;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
    },
  });
}

function error(code: string, status: number, detail?: string): Response {
  return json(detail === undefined ? { error: code } : { error: code, detail }, status);
}

async function readJson(request: Request): Promise<Record<string, unknown> | null> {
  const text = await request.text();
  if (text.length === 0 || text.length > 4096) return null;
  try {
    const parsed = JSON.parse(text);
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function decodeKey(value: unknown): Uint8Array | null {
  if (typeof value !== 'string' || value.length > 88) return null;
  try {
    return b64uDecode(value);
  } catch {
    return null;
  }
}

function pairStub(env: Env, pairId: string): DurableObjectStub {
  return env.PAIR_ROOM.get(env.PAIR_ROOM.idFromName(pairId));
}

async function callRoom(env: Env, pairId: string, path: string, body: unknown): Promise<Response> {
  const stub = pairStub(env, pairId);
  return stub.fetch(`https://pair.internal${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const ip = request.headers.get('cf-connecting-ip') ?? 'unknown';

    try {
      if (request.method === 'GET' && url.pathname === '/health') {
        return json({
          status: 'ok',
          mode: 'cloud',
          protocol: 'sp1',
          serverVersion: SERVER_VERSION,
          turnEnabled: turnEnabled(env),
        });
      }

      if (request.method === 'GET' && url.pathname === '/v1/info') {
        const config = heartbeatConfig(env);
        const ice = await resolveIceServers(env);
        return json({
          protocol: 'sp1',
          mode: 'cloud',
          serverVersion: SERVER_VERSION,
          heartbeatMs: config.heartbeatMs,
          sessionTimeoutMs: config.sessionTimeoutMs,
          iceServers: ice.iceServers,
          turn: { enabled: ice.turnEnabled, ...(ice.warning ? { warning: ice.warning } : {}) },
        });
      }

      if (request.method === 'POST' && url.pathname === '/v1/pair/create') {
        if (!allowAttempt(`create:${ip}`, CREATE_LIMIT_PER_MINUTE)) return error('rate_limited', 429);
        const body = await readJson(request);
        if (!body) return error('bad_request', 400);
        const keyBytes = decodeKey(body.publicKey);
        if (!keyBytes || keyBytes.length !== 32) {
          return error('bad_request', 400, 'publicKey must be a base64url Ed25519 public key');
        }
        const claimedId = body.deviceId;
        if (typeof claimedId !== 'string' || claimedId.length === 0 || claimedId.length > 64) {
          return error('bad_request', 400, 'deviceId is required');
        }
        const olmKeyBytes = decodeKey(body.olmKey);
        if (!olmKeyBytes || olmKeyBytes.length !== 32) {
          return error('bad_request', 400, 'olmKey must be a 32-byte base64url Curve25519 identity key');
        }
        if (deviceIdFromPublicKey(keyBytes) !== claimedId) {
          return error('unauthorized', 403, 'deviceId does not match the supplied public key');
        }

        const pairId = newPairId();
        const invite = createInvite();
        const created = await callRoom(env, pairId, '/create', {
          pairId,
          deviceId: claimedId,
          publicKey: body.publicKey,
          olmKey: String(body.olmKey),
          inviteToken: invite.token,
        });
        if (!created.ok) return created;

        const wsUrl = `wss://${url.host}/v1/ws`;
        const qr = encodePairingQr({
          v: 1,
          proto: 'sp1',
          mode: 'cloud',
          wsUrl,
          pairId,
          invite: invite.token,
          expiresAt: invite.expiresAt,
        });
        return json({ pairId, role: 'A', invite: invite.token, inviteExpiresAt: invite.expiresAt, wsUrl, qr });
      }

      if (request.method === 'POST' && url.pathname === '/v1/pair/register') {
        if (!allowAttempt(`register:${ip}`, CREATE_LIMIT_PER_MINUTE)) return error('rate_limited', 429);
        const body = await readJson(request);
        if (!body) return error('bad_request', 400);
        const { pairId, invite, deviceId } = body;
        if (typeof pairId !== 'string' || !PAIR_ID_PATTERN.test(pairId)) return error('bad_request', 400, 'bad pairId');
        if (typeof invite !== 'string' || invite.length > 128) return error('bad_request', 400, 'bad invite');
        if (typeof deviceId !== 'string' || deviceId.length > 64) return error('bad_request', 400, 'bad deviceId');
        const keyBytes = decodeKey(body.publicKey);
        if (!keyBytes || keyBytes.length !== 32) return error('bad_request', 400, 'bad publicKey');
        const olmKeyBytes = decodeKey(body.olmKey);
        if (!olmKeyBytes || olmKeyBytes.length !== 32) return error('bad_request', 400, 'olmKey must be a 32-byte base64url Curve25519 identity key');

        const registered = await callRoom(env, pairId, '/register', {
          pairId,
          invite,
          deviceId,
          publicKey: body.publicKey,
          olmKey: String(body.olmKey),
        });
        if (!registered.ok) return registered;
        const payload = (await registered.json()) as Record<string, unknown>;
        return json({ ...payload, wsUrl: `wss://${url.host}/v1/ws` });
      }

      if (request.method === 'POST' && url.pathname === '/v1/pair/revoke') {
        const body = await readJson(request);
        if (!body || typeof body.pairId !== 'string' || !PAIR_ID_PATTERN.test(body.pairId)) {
          return error('bad_request', 400);
        }
        if (!isRecord(body.request)) return error('bad_request', 400);
        const revoked = await callRoom(env, body.pairId, '/revoke', {
          pairId: body.pairId,
          request: body.request,
        });
        if (!revoked.ok) return revoked;
        const payload = (await revoked.json()) as Record<string, unknown>;
        return json({ ...payload, wsUrl: `wss://${url.host}/v1/ws` });
      }

      if (request.method === 'GET' && url.pathname === '/v1/ws') {
        const pairId = url.searchParams.get('pair');
        if (pairId === null || !PAIR_ID_PATTERN.test(pairId)) return error('bad_request', 400, 'bad pair');
        const upgrade = request.headers.get('upgrade');
        if (!upgrade || upgrade.toLowerCase() !== 'websocket') {
          return error('upgrade_required', 426);
        }
        const stub = pairStub(env, pairId);
        const doUrl = new URL(request.url);
        doUrl.pathname = '/ws';
        doUrl.search = `?pair=${encodeURIComponent(pairId)}`;
        return stub.fetch(new Request(doUrl.toString(), request));
      }

      return error('not_found', 404);
    } catch {
      // Never leak stack traces or request bodies (they may contain ciphertext).
      return error('server_error', 500);
    }
  },
};
