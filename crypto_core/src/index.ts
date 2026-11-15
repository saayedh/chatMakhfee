/**
 * @secretplay/crypto-core — shared foundation for both SecretPlay relays.
 *
 * Nothing in this package can read a message: the end-to-end encryption lives
 * in the Android client (vodozemac/Olm). This package covers wire framing,
 * device authentication, session tokens, pairing invitations, and the
 * encrypted recovery package format.
 */

export * from './codec.ts';
export * from './frames.ts';
export * from './auth.ts';
export * from './pairing.ts';
export * from './recovery.ts';
export * from './admin.ts';
export * from './room.ts';
