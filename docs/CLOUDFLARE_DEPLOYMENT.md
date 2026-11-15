# Cloudflare deployment

One Worker plus one Durable Object class (`PairRoom`), SQLite-backed, free plan.

## Prerequisites

- Node.js 22.18+.
- A Cloudflare account (free) and the zone/subdomain `*.workers.dev` left enabled.
- `npx wrangler login` once (opens a browser). This project never asks for, stores
  or prints an API token. If you prefer a token, set `CLOUDFLARE_API_TOKEN` in your
  own shell before running the script — never in a file in this repo.

## Deploy

```bat
cd cloudflare
npm ci
npx wrangler login
cd ..
scripts\deploy-cloudflare.bat
```

The script: checks Node, installs pinned deps if missing, verifies
`wrangler whoami`, runs `npm run typecheck`, runs `npm test`, bundles with
`wrangler deploy --dry-run`, then deploys and prints the URL.

Manual equivalent:

```bat
cd cloudflare
npm test
npm run typecheck
npx wrangler deploy --dry-run --outdir=.wrangler\dry-run
npx wrangler deploy
```

Paste the printed `https://secretplay.<subdomain>.workers.dev` into
**Private → Network & pairing → Cloud → Worker URL**.

## Endpoints

| Method | Path | Notes |
| --- | --- | --- |
| POST | `/v1/pair/create` | First device creates the pair, returns `qr` + `inviteExpiresAt` |
| POST | `/v1/pair/register` | Second device redeems the QR |
| POST | `/v1/pair/revoke` | Signed revocation from an authorised device |
| GET | `/v1/ws?pair=<pairId>` | WebSocket upgrade, proxied to the Durable Object |
| POST | `/v1/turn/credentials` | Only when `TURN_ENABLED=true` and secrets are set |

## What is stored (and what is not)

SQLite inside the Durable Object: `pairs`, `devices` (role, device id, public
keys), `revocations`, invite hash + expiry, optional recovery metadata. That is
all. There is **no** message table, no ciphertext persistence, no attachments, no
queue. A test asserts the schema contains no content table. Ciphertext exists only
inside `webSocketMessage` while being forwarded; WebSocket hibernation keeps the
object evictable between messages.

## Free-plan fit

| Item | Free plan |
| --- | --- |
| Workers requests | 100,000/day, 10 ms CPU per request (the relay is I/O bound) |
| Durable Objects | SQLite-backed classes only — this is why `new_sqlite_classes` is used |
| DO duration | Free allowance applies; hibernation means an idle pair costs no duration |
| D1 / R2 / Queues / Containers | **Not used** — no paid or capacity-billed bindings |
| Observability | Disabled in `wrangler.jsonc` (`observability.enabled=false`) |

Cost control: two devices, one room, heartbeat every 5 s. Idle hibernation means
the object is evicted between messages. Nothing auto-upgrades; if you exceed the
free allowances Cloudflare starts returning errors rather than billing, unless you
add a paid plan yourself.

## TURN (optional, off by default)

Media is peer-to-peer. TURN exists only for networks that block a direct path.

- Default: `TURN_ENABLED=false`. No TURN endpoint is advertised; calls that cannot
  connect fail with an explicit message rather than silently degrading.
- Enabling requires both secrets:

```bat
cd cloudflare
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_KEY_API_TOKEN
```

then set `TURN_ENABLED` to `"true"` in `wrangler.jsonc` and redeploy.

- Code path: the Worker calls
  `POST https://rtc.live.cloudflare.com/v1/turn/keys/{keyId}/credentials/generate-ice-servers`
  with `Authorization: Bearer <TURN_KEY_API_TOKEN>` and returns short-lived ICE
  servers. The token never reaches the browser or the app.
- **Billing:** Cloudflare TURN is billed at **$0.05/GB** of relayed traffic. A
  TURN-relayed call therefore costs money and is the one part of this project that
  can generate a charge. Leave it off unless you need it.
- TURN relays WebRTC packets; it does not terminate the DTLS-SRTP media
  encryption. It does see source/destination IPs and traffic volume.

## Verification after deploy

1. `curl https://<worker>/v1/pair/create` with a POST returns a `pairId`; a GET
   returns 404/405 (it is not a public directory).
2. A WebSocket connection without a valid `hello` is closed with 4003.
3. Two phones pair; the second scan of the same QR is refused.
4. `wrangler tail` shows no message content — only lifecycle events.

## Rotating and removing

- Revoke a slot from the app (Security → Revoke the other device): the DO records
  the revocation and closes both sockets with `end:revoked`.
- `npx wrangler delete` removes the Worker and the Durable Object namespace; all
  pairing metadata goes with it. Phones must re-pair.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `whoami` fails | `npx wrangler login` again, or export `CLOUDFLARE_API_TOKEN` in your shell |
| Dry-run fails on a Node API | The Worker must not use Node built-ins; check `nodejs_compat` is not required by your change |
| WebSocket 1006 immediately | The DO rejected the hello: check signed timestamps (±120 s drift) and that the device is registered |
| Calls never connect on mobile data | Expected with TURN off; enable TURN or use local mode |
| `pair_not_found` | Wrong URL or the pair was deleted; re-pair |
