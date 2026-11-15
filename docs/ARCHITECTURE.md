# Architecture

Two Android phones, one relay at a time, nothing stored in between.

```
┌────────────────────┐        sp1 over WSS/WS         ┌──────────────────────┐
│  Android A         │◀──────────────────────────────▶│  Cloudflare Worker   │
│  game shell        │                                │  + PairRoom DO       │
│  private shell     │                                │  (SQLite metadata)   │
│  Olm ratchet       │◀──── WebRTC DTLS-SRTP ────┐    └──────────────────────┘
└────────────────────┘                          │              or
┌────────────────────┐        sp1 over WS       │    ┌──────────────────────┐
│  Android B         │◀─────────────────────────┴───▶│  Laptop relay        │
│  same app          │                               │  (in memory only)    │
└────────────────────┘                               └──────────────────────┘
        └────────────── audio: phone to phone, never through a relay ────────┘
```

## Components

| Path | Role |
| --- | --- |
| `crypto_core/` | TypeScript source of truth for frames, canonical JSON, Ed25519 hello, HMAC session tokens, pairing, recovery envelope, `RoomMachine` |
| `cloudflare/` | Worker router (`/create`, `/register`, `/revoke`, `/ws`, TURN credentials), `PairRoom` Durable Object with WebSocket hibernation and SQLite metadata |
| `local_server/` | Fastify + `ws` relay for LAN/offline use, in-memory two-slot store, QR banner, admin endpoints |
| `android_app/lib/game/` | The public shell: a real deduction game (board, palette, feedback, hints, star ratings) |
| `android_app/lib/app/` | Theme, routing, providers, private shell |
| `android_app/lib/authentication/` | Passphrase policy, Argon2id verifier, biometrics, rate limiting, lock controller |
| `android_app/lib/cryptography/` | Olm account/session/SAS driver, canonical JSON, envelope |
| `android_app/lib/sessions/` | Client session machine, heartbeat, teardown |
| `android_app/lib/networking/` | Pairing, QR, transport, protocol validators |
| `android_app/lib/voice/` | WebRTC peer connection, call controller, decrypted signal bus |
| `android_app/lib/recovery/` | Argon2id + XChaCha20-Poly1305 recovery package |
| `android_app/lib/storage/` | Keystore-backed store and preferences |

## Session lifecycle

```
lock ──unlock(passphrase|biometric)──▶ idle
idle ──connect(hello)──▶ connecting ──welcome──▶ waitingForPeer ──peer joined──▶ active
active ──peer left──▶ waitingForPeer ──peer rejoins──▶ active
active|waitingForPeer ──err/timeout/bye/end/lock──▶ ended ──▶ lock, ratchet destroyed
```

Both relays share one `RoomMachine`: it owns the two slots, rejects a third
socket, refuses `msg`/`signal` unless both devices are present, enforces the rate
budget and replay guards, and emits `end` to both sides on any terminal event.
A relay restart therefore destroys every session by construction.

On the phone, `SessionController` owns the socket, the ratchet and the in-memory
message list. `LockController` never touches widgets for teardown: it calls a
`LockSink` that stops the call, clears signals, **ends the session** (bye + socket
close + ratchet destroyed) and then the UI overlay covers everything. Review
finding F1: the session-ending call was missing at first and was added back.

## Why "session only" is structural, not a policy

- No message table exists in `cloudflare/src/protocol_rules.ts`; a test
  (`assertMetadataOnlySchema`) fails if one is ever added.
- The Durable Object keeps ciphertext only in `webSocketMessage` scope.
- The laptop relay keeps ciphertext in a per-socket buffer that is dropped after
  delivery, and its store has no message collection at all.
- The app has no database dependency: `flutter_secure_storage` holds long-term
  keys and preferences, never chat.
- There is no reconnect queue on either side, so nothing can be replayed to a
  device that was away.

## Identity and pairing

- Long-term device identity = vodozemac `Account` (Ed25519 + Curve25519), pickled
  and encrypted with a random 32-byte secret held in the Keystore-backed store.
- `deviceId = "d_" + b64u(sha256(ed25519PublicKey)[0..16])`, computed identically
  on both relays and in Dart.
- Both modes authenticate each connection with an Ed25519 signed hello over the
  registered device key, with a single-use nonce. Local mode used to send an HMAC
  bearer token over cleartext `ws://`; that was removed in review (see
  [AUDIT.md](AUDIT.md) F2) because a sniffed token could be replayed.
- Pairing fills two slots and stops. Recovery restores membership metadata only;
  the peer must re-approve a new identity via the SAS code.

## Voice

`flutter_webrtc` peer connection per call; offer/answer/ICE travel as Olm-sealed
`signal` frames. Local mode uses no STUN/TURN (host candidates only). Cloud mode
uses Cloudflare STUN and, optionally, TURN; TURN is disabled by default because it
bills per GB. Media never transits Workers, Durable Objects or the laptop relay.

## Failure behaviour (by design)

| Event | Result |
| --- | --- |
| Phone backgrounded, screen off, recents | Immediate lock, session ended, peer notified |
| Relay unreachable | Socket closes, session ended, app locks |
| Heartbeat silence > 20 s | Timeout, both sides lock |
| Third device attempts to pair | Refused (no slot, expired invite) |
| Unknown/revoked device connects | 403 / close 4003 |
| Relay restart | All sessions gone; nothing to resume |
| Forged or replayed frame | Dropped; session survives |
