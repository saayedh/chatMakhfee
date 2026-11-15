import { WebSocket } from 'ws';

import {
  b64u,
  canonicalJson,
  createDeviceIdentity,
  hmacSha256,
  randomBytes,
  sha256,
  signHello,
  type CipherEnvelope,
  type Role,
} from '../../../crypto_core/src/index.ts';
import { loadConfig, type LocalServerConfig } from '../../src/config.ts';
import { createLocalServer, type LocalServer } from '../../src/server.ts';
import type { InviteState } from '../../src/store.ts';

export const TEST_ADMIN_TOKEN = 'test-admin-token-0123456789';

const BASE_ENV: Record<string, string> = {
  SECRETPLAY_PORT: '0',
  SECRETPLAY_BIND: '127.0.0.1',
  SECRETPLAY_QUIET: '1',
  SECRETPLAY_ALLOW_LAN: '0',
  SECRETPLAY_ADMIN_TOKEN: TEST_ADMIN_TOKEN,
  SECRETPLAY_HEARTBEAT_MS: '1000',
  SECRETPLAY_SESSION_TIMEOUT_MS: '3000',
  SECRETPLAY_SWEEP_INTERVAL_MS: '200',
};

export interface TestRelay {
  server: LocalServer;
  base: string;
  port: number;
  config: LocalServerConfig;
  close: () => Promise<void>;
}

export async function startRelay(env: Record<string, string> = {}): Promise<TestRelay> {
  const config = loadConfig({ ...BASE_ENV, ...env });
  const server = await createLocalServer(config);
  const { port } = await server.listen();
  return {
    server,
    base: `http://127.0.0.1:${port}`,
    port,
    config,
    close: () => server.close(),
  };
}

export interface TestDevice {
  secretKey: Uint8Array;
  publicKey: Uint8Array;
  publicKeyB64: string;
  deviceId: string;
  olmIdentityKeyB64: string;
}

/// Test-only keyring: `helloFrame` signs with the registered device's secret,
/// exactly like the app does. Keeping it here means every existing call site
/// exercises the real signed-hello path instead of a bearer token.
const deviceSecrets = new Map<string, Uint8Array>();
const registeredOlmIdentities = new Map<string, string>();

export function makeDevice(): TestDevice {
  const identity = createDeviceIdentity();
  deviceSecrets.set(identity.deviceId, identity.secretKey);
  const olmIdentityKeyB64 = b64u(randomBytes(32));
  registeredOlmIdentities.set(identity.deviceId, olmIdentityKeyB64);
  return {
    ...identity,
    publicKeyB64: b64u(identity.publicKey),
    olmIdentityKeyB64,
  };
}

export interface RegisterResponse {
  status: number;
  body: Record<string, unknown>;
}

export function localRegistrationBody(
  relay: TestRelay,
  invite: string,
  challenge: string,
  device: TestDevice,
  deviceIdOverride?: string,
): Record<string, string> {
  const deviceId = deviceIdOverride ?? device.deviceId;
  const context = {
    domain: 'secretplay.local-pairing.v1',
    pairId: relay.server.store.pairId,
    challenge,
    deviceId,
    publicKey: device.publicKeyB64,
    olmKey: device.olmIdentityKeyB64,
  };
  const proofKey = sha256(`secretplay.invite.v1|${invite}`);
  return {
    challenge,
    proof: b64u(hmacSha256(proofKey, canonicalJson(context))),
    deviceId,
    publicKey: device.publicKeyB64,
    olmKey: device.olmIdentityKeyB64,
  };
}

export async function register(
  relay: TestRelay,
  invite: string,
  device: TestDevice,
): Promise<RegisterResponse> {
  const challengeResponse = await fetch(
    `${relay.base}/v1/pair/challenge?pairId=${encodeURIComponent(relay.server.store.pairId)}`,
  );
  const challengeBody = (await challengeResponse.json()) as Record<string, unknown>;
  if (!challengeResponse.ok) {
    return { status: challengeResponse.status, body: challengeBody };
  }
  const challenge = challengeBody.challenge;
  if (typeof challenge !== 'string') throw new Error('pairing challenge missing');
  const response = await fetch(`${relay.base}/v1/pair/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(localRegistrationBody(relay, invite, challenge, device)),
  });
  return { status: response.status, body: (await response.json()) as Record<string, unknown> };
}

/** A hello that also announces public Olm material, as the real app does. */
export function helloWithOlm(params: {
  token: string;
  pairId: string;
  deviceId: string;
  role: Role;
}): Record<string, unknown> {
  return helloFrame(params);
}

export async function registerPair(relay: TestRelay): Promise<{
  deviceA: TestDevice;
  deviceB: TestDevice;
  tokenA: string;
  tokenB: string;
  roleA: Role;
  roleB: Role;
}> {
  const deviceA = makeDevice();
  const inviteA = relay.server.currentInvite();
  if (!inviteA) throw new Error('relay did not create an invitation');
  const first = await register(relay, inviteA.token, deviceA);
  if (first.status !== 200) throw new Error(`register A failed: ${JSON.stringify(first.body)}`);

  const inviteB = relay.server.currentInvite();
  if (!inviteB) throw new Error('relay did not rotate the invitation after slot A');
  const deviceB = makeDevice();
  const second = await register(relay, inviteB.token, deviceB);
  if (second.status !== 200) throw new Error(`register B failed: ${JSON.stringify(second.body)}`);

  return {
    deviceA,
    deviceB,
    // Local WebSocket authentication uses signed Ed25519 hellos. These
    // sentinel values only exercise rejection of the obsolete token auth mode.
    tokenA: 'obsolete-token-a',
    tokenB: 'obsolete-token-b',
    roleA: first.body.role as Role,
    roleB: second.body.role as Role,
  };
}

export function helloFrame(params: {
  /** Retained so existing call sites keep reading naturally; never sent. */
  token?: string;
  pairId: string;
  deviceId: string;
  role: Role;
  olmIdentityKey?: string;
}): Record<string, unknown> {
  const ts = Date.now();
  const nonce = b64u(randomBytes(16));
  // Unknown device ids (the intruder tests) sign with a throwaway key, so the
  // relay rejects them on signature or identity rather than on frame shape.
  const secretKey = deviceSecrets.get(params.deviceId) ?? randomBytes(32);
  const olm = {
    identityKey: params.olmIdentityKey ?? registeredOlmIdentities.get(params.deviceId) ?? b64u(randomBytes(32)),
    oneTimeKey: b64u(randomBytes(32)),
  };
  return {
    v: 1,
    t: 'hello',
    proto: 'sp1',
    pairId: params.pairId,
    deviceId: params.deviceId,
    role: params.role,
    auth: {
      kind: 'signed',
      ts,
      nonce,
      sig: signHello(secretKey, {
        pairId: params.pairId,
        deviceId: params.deviceId,
        role: params.role,
        ts,
        nonce,
        olm,
      }),
    },
    olm,
  };
}

export function msgFrame(id: string, cipher: CipherEnvelope): Record<string, unknown> {
  return { v: 1, t: 'msg', id, cipher };
}

export function signalFrame(id: string, cipher: CipherEnvelope): Record<string, unknown> {
  return { v: 1, t: 'signal', id, cipher };
}

type Frame = Record<string, unknown>;

interface Waiter {
  predicate: (frame: Frame) => boolean;
  resolve: (frame: Frame) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

export class TestClient {
  readonly ws: WebSocket;
  readonly received: Frame[] = [];
  readonly label: string;
  private readonly waiters: Waiter[] = [];
  private closeInfo: { code: number; reason: string } | null = null;

  private constructor(ws: WebSocket, label: string) {
    this.ws = ws;
    this.label = label;
    ws.on('message', (data) => {
      let frame: Frame;
      try {
        frame = JSON.parse(data.toString()) as Frame;
      } catch {
        return;
      }
      this.received.push(frame);
      for (const waiter of [...this.waiters]) {
        if (waiter.predicate(frame)) {
          clearTimeout(waiter.timer);
          this.waiters.splice(this.waiters.indexOf(waiter), 1);
          waiter.resolve(frame);
        }
      }
    });
    ws.on('close', (code, reason) => {
      this.closeInfo = { code, reason: reason.toString() };
      for (const waiter of [...this.waiters]) {
        clearTimeout(waiter.timer);
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        waiter.reject(new Error(`${label} closed (${code} ${reason.toString()}) before the expected frame`));
      }
    });
  }

  static async connect(url: string, hello: Record<string, unknown>, label: string): Promise<TestClient> {
    const ws = new WebSocket(url);
    const client = new TestClient(ws, label);
    await new Promise<void>((resolve, reject) => {
      ws.once('open', () => resolve());
      ws.once('error', (error) => reject(error));
    });
    ws.send(JSON.stringify(hello));
    return client;
  }

  waitFor(predicate: (frame: Frame) => boolean, timeoutMs = 4000): Promise<Frame> {
    const existing = this.received.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise<Frame>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.splice(
          this.waiters.findIndex((waiter) => waiter.timer === timer),
          1,
        );
        reject(new Error(`timed out waiting on ${this.label}; received ${JSON.stringify(this.received)}`));
      }, timeoutMs);
      this.waiters.push({ predicate, resolve, reject, timer });
    });
  }

  next(type: string, timeoutMs = 4000): Promise<Frame> {
    return this.waitFor((frame) => frame.t === type, timeoutMs);
  }

  send(frame: Record<string, unknown>): void {
    this.ws.send(JSON.stringify(frame));
  }

  async waitClosed(timeoutMs = 4000): Promise<{ code: number; reason: string }> {
    if (this.closeInfo) return this.closeInfo;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${this.label} did not close`)), timeoutMs);
      this.ws.once('close', (code, reason) => {
        clearTimeout(timer);
        resolve({ code, reason: reason.toString() });
      });
    });
  }

  get isClosed(): boolean {
    return this.closeInfo !== null;
  }

  close(): void {
    try {
      this.ws.close();
    } catch {
      // ignore
    }
  }
}

export function idle(ms = 150): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
