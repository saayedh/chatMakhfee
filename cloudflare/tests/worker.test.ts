import { test } from 'node:test';
import assert from 'node:assert/strict';

import worker from '../src/index.ts';
import { parsePairingQr, createDeviceIdentity, b64u } from '../../crypto_core/src/index.ts';
import type { Env } from '../src/env.ts';
import { resetIceCache } from '../src/turn.ts';

interface Recorded {
  path: string;
  body: unknown;
}

function fakeEnv(
  handler?: (request: Request) => Response | Promise<Response>,
  overrides: Partial<Env> = {},
): { env: Env; recorded: Recorded[] } {
  const recorded: Recorded[] = [];
  const stub = {
    async fetch(input: Request | string, init?: RequestInit): Promise<Response> {
      const request = typeof input === 'string' ? new Request(input, init) : input;
      const url = new URL(request.url);
      const text = request.method === 'POST' ? await request.text() : '';
      recorded.push({ path: url.pathname, body: text ? JSON.parse(text) : null });
      if (handler) return handler(request);
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    },
  };
  const env = {
    PAIR_ROOM: {
      idFromName: (name: string) => name,
      get: () => stub,
    } as unknown as DurableObjectNamespace,
    ...overrides,
  } as Env;
  return { env, recorded };
}

async function call(request: Request, env: Env): Promise<Response> {
  return worker.fetch(request, env, {} as ExecutionContext);
}

function post(path: string, body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`https://secretplay.example${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'cf-connecting-ip': '203.0.113.7', ...headers },
    body: JSON.stringify(body),
  });
}

test('health reports cloud mode without leaking anything', async () => {
  const { env } = fakeEnv();
  const response = await call(new Request('https://secretplay.example/health'), env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const body = (await response.json()) as Record<string, unknown>;
  assert.equal(body.status, 'ok');
  assert.equal(body.mode, 'cloud');
  assert.equal(body.turnEnabled, false);
  assert.equal(JSON.stringify(body).includes('token'), false);
});

test('info offers Cloudflare STUN and reports TURN as disabled by default', async () => {
  resetIceCache();
  const { env } = fakeEnv();
  const response = await call(new Request('https://secretplay.example/v1/info'), env);
  const body = (await response.json()) as {
    iceServers: Array<{ urls: string[] }>;
    turn: { enabled: boolean; warning?: string };
    heartbeatMs: number;
    sessionTimeoutMs: number;
  };
  assert.equal(response.status, 200);
  assert.deepEqual(body.iceServers, [{ urls: ['stun:stun.cloudflare.com:3478'] }]);
  assert.equal(body.turn.enabled, false);
  assert.equal(body.turn.warning, 'turn_disabled');
  assert.equal(body.heartbeatMs, 5000);
  assert.equal(body.sessionTimeoutMs, 20000);
});

test('TURN enabled without secrets stays on STUN and says why', async () => {
  resetIceCache();
  const { env } = fakeEnv(undefined, { TURN_ENABLED: 'true' });
  const response = await call(new Request('https://secretplay.example/v1/info'), env);
  const body = (await response.json()) as { turn: { enabled: boolean; warning?: string } };
  assert.equal(body.turn.enabled, false);
  assert.equal(body.turn.warning, 'turn_not_configured');
});

test('creating a pair registers device A and returns a scannable QR', async () => {
  const identity = createDeviceIdentity();
  const { env, recorded } = fakeEnv();
  const response = await call(
    post('/v1/pair/create', { deviceId: identity.deviceId, publicKey: b64u(identity.publicKey), olmKey: b64u(new Uint8Array(32).fill(7)) }),
    env,
  );
  assert.equal(response.status, 200);
  const body = (await response.json()) as Record<string, string>;

  assert.match(String(body.pairId), /^pair-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{2}$/);
  assert.match(String(body.wsUrl), /^wss:\/\/secretplay\.example\/v1\/ws$/);

  const parsed = parsePairingQr(String(body.qr));
  assert.equal(parsed.ok, true);
  if (parsed.ok) {
    assert.equal(parsed.qr.mode, 'cloud');
    assert.equal(parsed.qr.pairId, body.pairId);
    assert.equal(parsed.qr.invite, body.invite);
  }

  assert.equal(recorded.length, 1);
  assert.equal(recorded[0]?.path, '/create');
  const forwarded = recorded[0]?.body as Record<string, unknown>;
  assert.equal(forwarded.pairId, body.pairId);
  assert.equal(forwarded.inviteToken, body.invite, 'the DO receives the token only to hash it');
});

test('create rejects a device id that does not match its key', async () => {
  const identity = createDeviceIdentity();
  const { env, recorded } = fakeEnv();
  const response = await call(
    post('/v1/pair/create', { deviceId: 'd_someone_else', publicKey: b64u(identity.publicKey), olmKey: b64u(new Uint8Array(32).fill(7)) }),
    env,
  );
  assert.equal(response.status, 403);
  assert.equal(recorded.length, 0, 'nothing is created for an invalid identity');
});

test('create rejects malformed bodies', async () => {
  const { env } = fakeEnv();
  for (const body of [{}, { deviceId: 'x' }, { deviceId: 'x', publicKey: 'not base64!' }]) {
    const response = await call(post('/v1/pair/create', body), env);
    assert.equal(response.status, 400);
  }
});

test('register forwards to the DO and preserves its refusal', async () => {
  const { env } = fakeEnv(
    () => new Response(JSON.stringify({ error: 'pair_full' }), { status: 409, headers: { 'content-type': 'application/json' } }),
  );
  const identity = createDeviceIdentity();
  const response = await call(
    post('/v1/pair/register', {
      pairId: 'pair-ABCD-EFGH-12',
      invite: 'invite-token-value',
      deviceId: identity.deviceId,
      publicKey: b64u(identity.publicKey),
      olmKey: b64u(new Uint8Array(32).fill(8)),
    }),
    env,
  );
  assert.equal(response.status, 409);
  assert.equal(((await response.json()) as Record<string, unknown>).error, 'pair_full');
});

test('register returns the peer identity for Olm bootstrap', async () => {
  const identity = createDeviceIdentity();
  const { env } = fakeEnv(
    () =>
      new Response(
        JSON.stringify({ role: 'B', peer: { deviceId: 'd_peer', publicKey: 'cGVlcktleQ' } }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      ),
  );
  const response = await call(
    post('/v1/pair/register', {
      pairId: 'pair-ABCD-EFGH-12',
      invite: 'invite-token-value',
      deviceId: identity.deviceId,
      publicKey: b64u(identity.publicKey),
      olmKey: b64u(new Uint8Array(32).fill(8)),
    }),
    env,
  );
  const body = (await response.json()) as Record<string, unknown>;
  assert.equal(body.role, 'B');
  assert.equal((body.peer as Record<string, string>).deviceId, 'd_peer');
  assert.equal(body.wsUrl, 'wss://secretplay.example/v1/ws');
});

test('websocket proxy requires a valid pair and an upgrade', async () => {
  const { env } = fakeEnv();
  const plain = await call(new Request('https://secretplay.example/v1/ws?pair=pair-ABCD-EFGH-12'), env);
  assert.equal(plain.status, 426);

  const noPair = await call(
    new Request('https://secretplay.example/v1/ws', { headers: { upgrade: 'websocket' } }),
    env,
  );
  assert.equal(noPair.status, 400);

  const badPair = await call(
    new Request('https://secretplay.example/v1/ws?pair=..%2F..%2Fetc', { headers: { upgrade: 'websocket' } }),
    env,
  );
  assert.equal(badPair.status, 400);
});

test('the websocket proxy rewrites to the DO /ws path', async () => {
  // Node's Response cannot represent a 101; the DO returns it in production.
  // Here we assert the Worker proxies the upgrade to the right DO path.
  const { env, recorded } = fakeEnv(() => new Response(null, { status: 200 }));
  const response = await call(
    new Request('https://secretplay.example/v1/ws?pair=pair-ABCD-EFGH-12', { headers: { upgrade: 'websocket' } }),
    env,
  );
  assert.equal(response.status, 200);
  assert.equal(recorded[0]?.path, '/ws');
});

test('unknown routes are 404 and revocation requires a signed request object', async () => {
  const { env } = fakeEnv();
  assert.equal((await call(new Request('https://secretplay.example/nope'), env)).status, 404);
  assert.equal((await call(post('/v1/pair/revoke', { pairId: 'pair-ABCD-EFGH-12' }), env)).status, 400);
});

test('pair creation is rate limited per client IP', async () => {
  const identity = createDeviceIdentity();
  const { env } = fakeEnv();
  let lastStatus = 0;
  for (let index = 0; index < 22; index += 1) {
    const response = await call(
      post('/v1/pair/create', { deviceId: identity.deviceId, publicKey: b64u(identity.publicKey), olmKey: b64u(new Uint8Array(32).fill(7)) }, {
        'cf-connecting-ip': '198.51.100.99',
      }),
      env,
    );
    lastStatus = response.status;
  }
  assert.equal(lastStatus, 429);
});
