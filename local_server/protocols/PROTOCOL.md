# sp1 v1 — the wire protocol both relays speak

One protocol, two transports. The Cloudflare Durable Object and the laptop relay
use the same frames, the same rules and the same `RoomMachine` (from
`crypto_core`), so an app build cannot accidentally work against one and not the
other.

- Text frames: UTF-8 JSON, maximum 16 KiB. Binary frames are rejected.
- `v` is always `1`; `t` is the frame type; `proto` is `sp1` on `hello`.
- ids and nonces are base64url without padding.
- Anything unknown, oversized or malformed is rejected; the receiver must not
  guess. Oversized frames close with **1009**, unauthorised with **4003**,
  rate-limited with **4008**, session ended with **4000**.

## Handshake

```jsonc
// client -> relay (cloud mode: Ed25519 signature)
{ "v":1, "t":"hello", "proto":"sp1", "pairId":"pair-...", "deviceId":"d_...",
  "role":"A",
  "auth":{ "kind":"signed", "ts":1731600000000, "nonce":"...", "sig":"..." },
  "olm":{ "identityKey":"...", "oneTimeKey":"..." } }

// client -> relay (local mode: same signature, verified against the key
// registered during QR pairing; the pairing token is never sent on the wire)
{ "v":1, "t":"hello", "proto":"sp1", "pairId":"pair-...", "deviceId":"d_...",
  "role":"B",
  "auth":{ "kind":"signed", "ts":1731600000000, "nonce":"...", "sig":"..." },
  "olm":{ "identityKey":"...", "oneTimeKey":"..." } }
```

The signed payload is canonical JSON (keys sorted) over
`{domain:"secretplay.hello.v1", proto, v, pairId, deviceId, role, ts, nonce}`.
Timestamps outside ±120 s are refused, and nonces are single-use per room.

Both relays require `kind:"signed"`. `kind:"token"` is refused with 4003: a
bearer token on a cleartext LAN socket could be sniffed and replayed, while a
signature cannot be turned into a credential for a different connection. Local
pairing still returns a token as a receipt, but it is never presented to the
WebSocket.

```jsonc
// relay -> client
{ "v":1, "t":"welcome", "sessionId":"s_...", "role":"A", "peerPresent":false,
  "peer":{ "deviceId":"d_...", "olmIdentityKey":"...", "olmOneTimeKey":"..." } }
{ "v":1, "t":"peer", "state":"joined", "deviceId":"d_...", "olmIdentityKey":"...", "olmOneTimeKey":"..." }
{ "v":1, "t":"peer", "state":"left",   "deviceId":"d_..." }
```

`peer` on `welcome` is present only if the other device was already connected.
`olmOneTimeKey` is fresh per connection and never stored: the app uses it to start
a brand-new ratchet each session.

## Chat and signalling

```jsonc
{ "v":1, "t":"msg",    "id":"m_...", "cipher":{ "senderKey":"...", "kind":1, "body":"...", "msgId":"m_...", "sentAt":1731600000000 } }
{ "v":1, "t":"signal", "id":"s_...", "cipher":{ ... } }   // offer / answer / ice / hangup / sas
{ "v":1, "t":"msg",    "id":"m_...", "seq":12, "cipher":{ ... } }   // relay -> client adds seq
```

The relay checks `id` uniqueness per session (replay guard), the size caps, the
rate budget, and that both slots are present. It does not parse `cipher` and has
no notion of plaintext. `signal` is the only path used by WebRTC and by the SAS
device-verification exchange.

## Heartbeat and teardown

```jsonc
{ "v":1, "t":"ping", "ts":1731600000000 }        // client every 5 s (configurable)
{ "v":1, "t":"pong", "ts":1731600000000 }
{ "v":1, "t":"bye",  "reason":"user_exit" }       // or "lock"
{ "v":1, "t":"end",  "reason":"peer_locked" }     // relay -> both devices
{ "v":1, "t":"err",  "code":"rate_limited", "detail":"..." }
```

`end` reasons: `peer_left`, `peer_locked`, `timeout`, `revoked`, `replaced`,
`server_shutdown`, `protocol_error`. Any `end` is terminal: the app wipes session
state, clears the ratchet and locks. There is no resume and no replay.

## Pairing

| Mode | Request | Response |
| --- | --- | --- |
| Local | `GET /v1/pair/challenge?pairId=...`, then `POST /v1/pair/register {challenge, proof, deviceId, publicKey, olmKey}` | `{pairId, role, wsUrl, peer?}` |
| Cloud, first | `POST /v1/pair/create {deviceId, publicKey, olmKey}` | `{pairId, role, wsUrl, qr, inviteExpiresAt}` |
| Cloud, second | `POST /v1/pair/register {pairId, invite, deviceId, publicKey, olmKey}` | `{pairId, role, wsUrl, peer}` |
| Cloud revoke | `POST /v1/pair/revoke {pairId, request}` | `{revoked:{role,deviceId}}` |

The QR payload is `{v:1, proto:"sp1", mode:"local"|"cloud", wsUrl, httpUrl?(local),
pairId, invite, expiresAt}`. Invitations are single-use, expire (10 minutes by
default) and cannot be replayed. In local mode the QR invitation is never included
in the registration POST body: the client obtains a 30-second challenge and sends
an HMAC-SHA256 proof bound to the pair, challenge, device id and both public keys.
The challenge is consumed before proof validation, so replaying the POST fails.
The bootstrap and WebSocket transports are still cleartext on the LAN; this proof
reduces passive QR-token disclosure but does not replace pinned TLS against an
active LAN attacker. There is no third slot, no invitation list and no way to
enumerate pairs.

The revoke request is Ed25519-signed by the requesting device over
`{domain:"secretplay.revoke.v1", proto, v, pairId, requesterRole,
requesterDeviceId, targetRole, ts, nonce}` and verified against the public key
registered for that slot. A device cannot revoke its own slot, timestamps must be
within ±120 s, and each nonce is single-use.

## Recovery package (at rest, not on the wire)

`{v:1, kind:"sp1-recovery-sealed", kdf:{name:"argon2id",m:65536,t:3,p:1,dkLen:32},
salt, nonce, aad:"secretplay.recovery.v1", ct}` where `ct` is XChaCha20-Poly1305
over canonical JSON membership metadata. No message, key or buffer is included.
See [docs/RECOVERY.md](../../docs/RECOVERY.md).
