# local_server — the laptop relay (offline / LAN mode)

Fastify + `ws` on Node.js 22.18+. Everything is in memory: pairing slots, session
tokens, invitations and live sockets. There is no database, no message store, no
queue, and no outbound network call. After `npm ci` it starts with the Internet
unplugged.

## Install once (needs Internet), then run offline

```bat
scripts\install-local.bat     :: npm ci + npm test, copies .env.example -> .env
scripts\run-local.bat         :: prints LAN addresses, QR, admin token
scripts\stop-local.bat        :: or Ctrl+C
```

Direct:

```bat
cd local_server
npm ci
npm start            :: node --env-file-if-exists=.env src/main.ts
```

## What it prints

- every private LAN IPv4 with its interface name, plus the port;
- the pair id and the slot the next phone will take (A or B only);
- a QR code containing `{mode:"local", httpUrl, wsUrl, pairId, invite, expiresAt}`;
- a console-only admin token (random per launch unless `SECRETPLAY_ADMIN_TOKEN`);
- the Windows Mobile Hotspot checklist and firewall hint.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Liveness, pair id, slots filled, session phase (no secrets) |
| GET | `/v1/info` | Protocol version, heartbeat/timeout, pairing state |
| GET | `/v1/pair/challenge?pairId=...` | Create a 30-second, one-use local pairing challenge |
| POST | `/v1/pair/register` | Redeem the challenge with an HMAC proof; raw QR invitation is not sent in the request |
| POST | `/v1/admin/invite` | Mint a fresh invitation (admin token required) |
| POST | `/v1/admin/revoke` | Revoke a slot (admin token required) |
| POST | `/v1/admin/reset` | Drop all pairing and live sessions (admin token required) |
| WS | `/v1/ws` | sp1 relay; requires an Ed25519-signed hello for one of the two registered device slots |

Admin calls need `Authorization: Bearer <admin token>`. Revoking a slot or
restarting the relay destroys every session: there is nothing to recover.

```bat
curl -X POST http://127.0.0.1:8787/v1/admin/revoke ^
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" ^
  -d "{\"role\":\"B\"}"
```

## Configuration

Every setting is documented in [`.env.example`](.env.example). Useful ones:

| Variable | Default | Notes |
| --- | --- | --- |
| `SECRETPLAY_BIND` | `0.0.0.0` | Needed for phones; `127.0.0.1` for loopback tests |
| `SECRETPLAY_PORT` | `8787` | Change if occupied |
| `SECRETPLAY_ALLOW_LAN` | `1` | Safety catch for non-loopback binds |
| `SECRETPLAY_INVITE_TTL_MS` | `600000` | Invitations expire and never repeat |
| `SECRETPLAY_HEARTBEAT_MS` | `5000` | Must match the app's expectation |
| `SECRETPLAY_SESSION_TIMEOUT_MS` | `20000` | Session ends after this much silence |
| `SECRETPLAY_RATE_PER_MINUTE` | `240` | Per device; over budget → `rate_limited` |
| `SECRETPLAY_ICE_SERVERS` | empty | Optional LAN Coturn, comma-separated |

`.env` is git-ignored. It contains no secrets: the admin token is generated per
launch and printed only in the console.

## Security posture

- Binds LAN only, and only two slots can ever be filled.
- A WebSocket is accepted only after an Ed25519-signed `hello` proves
  possession of the private key for one of the two registered device slots.
  No bearer session token is issued or persisted. The device proves key
  possession on each new WebSocket session.
- Ciphertext is forwarded and dropped. Nothing is written to disk; `.secretplay.pid`
  holds the process id and is deleted on shutdown.
- Invitations are single-use and expire; local QR invitations are used to derive
  a challenge-bound HMAC proof and are not sent in the cleartext registration
  body. The proof is one-use and the challenge expires after 30 seconds.
- Local HTTP/WebSocket transport is still cleartext. This protects the raw QR
  token from appearing in the registration request but does not authenticate
  the laptop against an active LAN man-in-the-middle. Use only a trusted private
  LAN; production hardening still requires TLS certificate pinning.
- Do not port-forward this server. It is not hardened for the public Internet and
  refuses to pretend otherwise.

## Tests

```bat
npm test          :: 29 node --test cases, in-process relay + stand-in codec
npm run typecheck
```

The test codec is a clearly labelled non-product stand-in for XChaCha20 (the real
encryption lives in the app). The relay never inspects ciphertext, so the tests
exercise framing, auth, replay, pairing and session rules rather than the cipher.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Phones cannot reach the LAN address | Allow Node.js through Defender Firewall on **private** networks; confirm both are on the same subnet |
| `EADDRINUSE` | Set `SECRETPLAY_PORT=8788` in `.env` |
| QR scans but registration fails | The invitation expired (10 min) or was already used; re-run `run-local.bat` |
| No private IPv4 listed | Wi-Fi or Mobile Hotspot is off; re-run after connecting |
| Call connects but no audio | LAN client isolation, or a VPN on a phone; retest with the hotspot |
