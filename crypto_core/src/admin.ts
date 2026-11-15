/**
 * Signed administrative requests.
 *
 * Revoking a device is the one privileged action a paired device may take on
 * its own. It is authenticated with the *requesting* device's Ed25519 identity
 * key, scoped to the pair, bound to a timestamp and nonce, and carries the
 * target role. The relay verifies it against the registered public keys; a
 * recovery package or an account backup can never authorize a revocation.
 */

import { ed25519 } from '@noble/curves/ed25519.js';
import { b64u, b64uDecode, canonicalJson, utf8 } from './codec.ts';
import { PROTOCOL_ID, PROTOCOL_VERSION, type Role } from './frames.ts';

export const MAX_ADMIN_SKEW_MS = 120_000;

export interface RevokeRequestInput {
  pairId: string;
  requesterRole: Role;
  requesterDeviceId: string;
  targetRole: Role;
  ts: number;
  nonce: string;
}

export interface SignedRevokeRequest {
  requesterRole: Role;
  requesterDeviceId: string;
  targetRole: Role;
  ts: number;
  nonce: string;
  sig: string;
}

export function revokeSigningPayload(input: RevokeRequestInput): Uint8Array {
  return utf8(
    canonicalJson({
      domain: 'secretplay.revoke.v1',
      proto: PROTOCOL_ID,
      v: PROTOCOL_VERSION,
      pairId: input.pairId,
      requesterRole: input.requesterRole,
      requesterDeviceId: input.requesterDeviceId,
      targetRole: input.targetRole,
      ts: input.ts,
      nonce: input.nonce,
    }),
  );
}

export function signRevokeRequest(secretKey: Uint8Array, input: RevokeRequestInput): SignedRevokeRequest {
  return {
    requesterRole: input.requesterRole,
    requesterDeviceId: input.requesterDeviceId,
    targetRole: input.targetRole,
    ts: input.ts,
    nonce: input.nonce,
    sig: b64u(ed25519.sign(revokeSigningPayload(input), secretKey)),
  };
}

export type VerifyRevokeResult = { ok: true } | { ok: false; detail: string };

export function verifyRevokeRequest(params: {
  pairId: string;
  request: SignedRevokeRequest;
  publicKey: Uint8Array;
  now: number;
  maxSkewMs?: number;
}): VerifyRevokeResult {
  const { request, publicKey } = params;
  const maxSkew = params.maxSkewMs ?? MAX_ADMIN_SKEW_MS;

  if (request.requesterRole === request.targetRole) {
    return { ok: false, detail: 'a device cannot revoke its own slot' };
  }
  if (Math.abs(params.now - request.ts) > maxSkew) {
    return { ok: false, detail: 'revoke request timestamp is outside the allowed window' };
  }
  let signature: Uint8Array;
  try {
    signature = b64uDecode(request.sig);
  } catch {
    return { ok: false, detail: 'revoke request signature is malformed' };
  }
  if (signature.length !== 64) return { ok: false, detail: 'revoke request signature must be 64 bytes' };

  const payload = revokeSigningPayload({
    pairId: params.pairId,
    requesterRole: request.requesterRole,
    requesterDeviceId: request.requesterDeviceId,
    targetRole: request.targetRole,
    ts: request.ts,
    nonce: request.nonce,
  });
  let valid = false;
  try {
    valid = ed25519.verify(signature, payload, publicKey);
  } catch {
    valid = false;
  }
  return valid ? { ok: true } : { ok: false, detail: 'revoke request signature is invalid' };
}
