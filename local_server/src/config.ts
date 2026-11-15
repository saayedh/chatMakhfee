/**
 * Local relay configuration.
 *
 * Defaults are chosen for the documented scenario: a laptop on a home Wi-Fi or
 * Windows Mobile Hotspot, two phones on the same network. Nothing here enables
 * an unauthenticated public service: every WebSocket requires an Ed25519-
 * signed hello from one of two public identities registered via one-time QR.
 */

export const DEFAULT_PORT = 8787;

export interface LocalServerConfig {
  /** Address to bind. 0.0.0.0 is required for phones to reach a laptop. */
  host: string;
  port: number;
  /** Refuse to bind a non-loopback address unless this is explicitly true. */
  allowLan: boolean;
  /** Do not print the QR/banner (used by automated tests). */
  quiet: boolean;
  inviteTtlMs: number;
  heartbeatMs: number;
  sessionTimeoutMs: number;
  sweepIntervalMs: number;
  /** Frames allowed per device per minute before `rate_limited`. */
  ratePerMinute: number;
  /** Optional extra ICE servers for WebRTC (e.g. a LAN Coturn), passed to apps. */
  extraIceServers: string[];
  /** Operator token for admin endpoints; generated when not supplied. */
  adminToken: string;
}

function intFromEnv(raw: string | undefined, fallback: number, min: number, max: number): number {
  if (raw === undefined || raw.trim() === '') return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new Error(`invalid numeric setting "${raw}" (expected integer ${min}..${max})`);
  }
  return value;
}

function boolFromEnv(raw: string | undefined, fallback: boolean): boolean {
  if (raw === undefined || raw.trim() === '') return fallback;
  const normalised = raw.trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalised)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalised)) return false;
  throw new Error(`invalid boolean setting "${raw}"`);
}

export function loadConfig(env: Record<string, string | undefined> = process.env): LocalServerConfig {
  const host = env.SECRETPLAY_BIND?.trim() || '0.0.0.0';
  const allowLan = boolFromEnv(env.SECRETPLAY_ALLOW_LAN, true);

  if (allowLan === false && host !== '127.0.0.1' && host !== 'localhost' && host !== '::1') {
    throw new Error(
      `refusing to bind ${host} with SECRETPLAY_ALLOW_LAN=0. Use SECRETPLAY_BIND=127.0.0.1 or allow LAN access.`,
    );
  }

  const extraIceServers = (env.SECRETPLAY_ICE_SERVERS ?? '')
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);

  return {
    host,
    // 0 asks the OS for a free port (used by the automated tests).
    port: intFromEnv(env.SECRETPLAY_PORT, DEFAULT_PORT, 0, 65535),
    allowLan,
    quiet: boolFromEnv(env.SECRETPLAY_QUIET, false),
    inviteTtlMs: intFromEnv(env.SECRETPLAY_INVITE_TTL_MS, 10 * 60 * 1000, 30_000, 60 * 60 * 1000),
    heartbeatMs: intFromEnv(env.SECRETPLAY_HEARTBEAT_MS, 5_000, 1_000, 60_000),
    sessionTimeoutMs: intFromEnv(env.SECRETPLAY_SESSION_TIMEOUT_MS, 20_000, 3_000, 300_000),
    sweepIntervalMs: intFromEnv(env.SECRETPLAY_SWEEP_INTERVAL_MS, 1_000, 100, 30_000),
    ratePerMinute: intFromEnv(env.SECRETPLAY_RATE_PER_MINUTE, 240, 30, 10_000),
    extraIceServers,
    adminToken: env.SECRETPLAY_ADMIN_TOKEN?.trim() || '',
  };
}
