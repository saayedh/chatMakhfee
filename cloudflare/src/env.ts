/**
 * Worker environment.
 *
 * Only one binding exists: the pair's SQLite Durable Object. TURN secrets are
 * optional and are set with `wrangler secret put`, never in source.
 */

export interface Env {
  PAIR_ROOM: DurableObjectNamespace;

  PROTOCOL_ID?: string;
  HEARTBEAT_MS?: string;
  SESSION_TIMEOUT_MS?: string;
  RATE_PER_MINUTE?: string;

  TURN_ENABLED?: string;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
}

export function envInt(value: string | undefined, fallback: number, min: number, max: number): number {
  if (value === undefined) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < min || parsed > max) return fallback;
  return parsed;
}

export function heartbeatConfig(env: Env): {
  heartbeatMs: number;
  sessionTimeoutMs: number;
  ratePerMinute: number;
} {
  return {
    heartbeatMs: envInt(env.HEARTBEAT_MS, 5000, 1000, 60_000),
    sessionTimeoutMs: envInt(env.SESSION_TIMEOUT_MS, 20_000, 3000, 300_000),
    ratePerMinute: envInt(env.RATE_PER_MINUTE, 240, 30, 10_000),
  };
}

export const PAIR_ID_PATTERN = /^[A-Za-z0-9_-]{6,40}$/;
