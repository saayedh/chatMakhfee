# SecretPlay — Security Policy

SecretPlay is a **personal, two-device** Android application. It is not a public
messaging platform and it makes no attempt to hide itself from Android. It
respects microphone indicators, foreground-service notifications, and every
other platform control.

## What the server can and cannot see

| Data | Cloudflare relay | Laptop relay |
| --- | --- | --- |
| Message plaintext | **Never** | **Never** |
| Olm session keys / ratchet state | **Never** | **Never** |
| Device private identity keys | **Never** | **Never** |
| Message ciphertext at rest | **Never** (memory only, dropped after relay) | **Never** (memory only) |
| Call media (audio) | **Never** — WebRTC P2P or TURN relay, never a Worker | **Never** — P2P on the LAN |
| Pair id, device ids, public identity keys | Stored (minimum metadata) | In memory only, lost on restart |
| Chat history | **Never** | **Never** |

The relays are *dumb pipes with an authorization check*. They validate that a
frame comes from one of exactly two registered devices of a known pair, and
forward it. They deliberately cannot decrypt anything.

## Reporting a vulnerability

This is a private personal project; there is no bug-bounty programme. If you
find an issue, open a local note or contact the maintainer directly. Do not
open a public issue containing message content, keys, pairing QR payloads, or
recovery packages.

## Non-negotiable rules for contributors

1. **No custom cryptography.** Olm (via `vodozemac`) provides message secrecy and
   forward secrecy; Argon2id + XChaCha20-Poly1305 (via `cryptography` /
   `@noble/*`) protect the passphrase and the recovery package. Do not add a
   hand-rolled scheme.
2. **No plaintext persistence.** No SQLite message table, no log lines with
   message bodies, no crash-report payloads with content, no notification
   bodies with content.
3. **No third-party analytics or crash reporting.** Not now, not "just for
   debugging".
4. **No secrets in source.** Recovery secrets, pairing tokens, TURN keys and
   signing material never enter the repository.
5. **Lock first.** Any change touching lifecycle handling must be tested against
   the locking invariants in `docs/SECURITY_TESTS.md`.

## Known, documented limitations

These are honest limitations, not bugs to hide:

- Dart/Java managed memory cannot be reliably zeroed; `Uint8List` buffers may be
  copied by the GC or the platform. Secret lifetime is minimised, not erased.
- Android may keep a thumbnail of the previous frame in the recents animation on
  some OEM builds. `FLAG_SECURE` plus a lock overlay is used, and
  `DETACHED`-style overlays are applied on task switch, but this is best-effort.
- WebRTC media is protected endpoint-to-endpoint by DTLS-SRTP. If the optional
  Cloudflare TURN relay is enabled, the relay forwards those already-encrypted
  packets; it cannot decrypt them, but it does see connection metadata.
- If both devices sit behind symmetric NAT without a relay, voice may fail. That
  is a network limitation, not a crypto failure; the UI must say so.
- The project has **not** received an independent security audit. Using an
  audited library is not the same as an audited system.
