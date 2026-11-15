/**
 * The local relay uses the shared room machine from crypto_core, so the laptop
 * and Cloudflare enforce byte-for-byte the same session rules. This module
 * keeps the local server's imports stable.
 */

export {
  RoomMachine,
  RoomMachine as SessionHub,
  CLOSE_SESSION_ENDED,
  CLOSE_REPLACED,
} from '../../crypto_core/src/room.ts';

export type {
  AttachInput,
  AttachResult,
  IdentityDirectory,
  RoomConfig,
  RoomConfig as HubConfig,
  SocketLike,
} from '../../crypto_core/src/room.ts';
