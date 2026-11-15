/**
 * ICE configuration.
 *
 * STUN (stun.cloudflare.com) is free and is always offered. TURN is **opt-in**
 * because it is billed at $0.05/GB outbound from Cloudflare to the TURN client
 * (see docs/CLOUDFLARE_DEPLOYMENT.md). With `TURN_ENABLED=false` — the default —
 * this module makes no outbound request at all.
 *
 * A TURN relay forwards already-DTLS-SRP-encrypted WebRTC packets; it cannot
 * decrypt the call. Media never passes through the Worker or the Durable Object.
 */

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export interface IceConfig {
  iceServers: IceServer[];
  turnEnabled: boolean;
  /** Machine-readable reason when TURN was requested but could not be used. */
  warning?: 'turn_disabled' | 'turn_not_configured' | 'turn_unavailable';
  ttlSeconds: number;
}

export interface TurnEnv {
  TURN_ENABLED?: string;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
}

export const CLOUDFLARE_STUN: IceServer = { urls: ['stun:stun.cloudflare.com:3478'] };
export const TURN_TTL_SECONDS = 3600;
const TURN_API = 'https://rtc.live.cloudflare.com/v1/turn/keys';
const CACHE_MS = 50 * 60 * 1000;

interface CacheEntry {
  config: IceConfig;
  expiresAt: number;
}

let cache: CacheEntry | null = null;

/** Test hook: forget any cached TURN credentials. */
export function resetIceCache(): void {
  cache = null;
}

export function turnEnabled(env: TurnEnv): boolean {
  return (env.TURN_ENABLED ?? 'false').trim().toLowerCase() === 'true';
}

function isIceServer(value: unknown): value is IceServer {
  if (typeof value !== 'object' || value === null) return false;
  const candidate = value as Record<string, unknown>;
  if (!Array.isArray(candidate.urls)) return false;
  if (!candidate.urls.every((entry) => typeof entry === 'string' && /^(stun|turn|turns):/.test(entry))) {
    return false;
  }
  if (candidate.username !== undefined && typeof candidate.username !== 'string') return false;
  if (candidate.credential !== undefined && typeof candidate.credential !== 'string') return false;
  return true;
}

function parseIceServers(payload: unknown): IceServer[] | null {
  if (typeof payload !== 'object' || payload === null) return null;
  const candidate = (payload as Record<string, unknown>).iceServers;
  if (!Array.isArray(candidate)) return null;
  if (!candidate.every(isIceServer)) return null;
  return candidate.map((server) => ({
    urls: server.urls,
    ...(server.username ? { username: server.username } : {}),
    ...(server.credential ? { credential: server.credential } : {}),
  }));
}

/**
 * Resolve the ICE servers handed to the Android app. Never throws: a broken
 * TURN configuration degrades to STUN-only and reports why.
 */
export async function resolveIceServers(
  env: TurnEnv,
  options: { fetchImpl?: typeof fetch; now?: number; ttlSeconds?: number } = {},
): Promise<IceConfig> {
  const now = options.now ?? Date.now();
  const ttlSeconds = options.ttlSeconds ?? TURN_TTL_SECONDS;

  if (!turnEnabled(env)) {
    return { iceServers: [CLOUDFLARE_STUN], turnEnabled: false, warning: 'turn_disabled', ttlSeconds };
  }
  const keyId = env.TURN_KEY_ID?.trim();
  const apiToken = env.TURN_KEY_API_TOKEN?.trim();
  if (!keyId || !apiToken) {
    return { iceServers: [CLOUDFLARE_STUN], turnEnabled: false, warning: 'turn_not_configured', ttlSeconds };
  }
  if (cache !== null && cache.expiresAt > now) return cache.config;

  const doFetch = options.fetchImpl ?? fetch;
  try {
    const response = await doFetch(`${TURN_API}/${encodeURIComponent(keyId)}/credentials/generate-ice-servers`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${apiToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ ttl: ttlSeconds }),
    });
    if (!response.ok) {
      return { iceServers: [CLOUDFLARE_STUN], turnEnabled: false, warning: 'turn_unavailable', ttlSeconds };
    }
    const servers = parseIceServers(await response.json());
    if (servers === null) {
      return { iceServers: [CLOUDFLARE_STUN], turnEnabled: false, warning: 'turn_unavailable', ttlSeconds };
    }
    const config: IceConfig = { iceServers: servers, turnEnabled: true, ttlSeconds };
    cache = { config, expiresAt: now + CACHE_MS };
    return config;
  } catch {
    return { iceServers: [CLOUDFLARE_STUN], turnEnabled: false, warning: 'turn_unavailable', ttlSeconds };
  }
}
