# Threat model

Scope: two people, two Android phones, one relay (Cloudflare or a laptop on the
same LAN). Personal use, not a public messenger.

## Assets

| Asset | Where it lives | Lifetime |
| --- | --- | --- |
| Message plaintext | Phone RAM only | Until the session ends or the app locks |
| Olm ratchet state | Phone RAM only | One session |
| Device identity (Ed25519/Curve25519) | Keystore-encrypted pickle | Until wiped |
| Passphrase verifier | Argon2id salt + hash in Keystore store | Until changed |
| Pairing metadata (public keys, pair id, slots) | Relay database / memory | Until revoked |
| Recovery package | User's offline copy | Until deleted |
| Voice media | WebRTC SRTP directly between phones | The call |
| Ciphertext in transit | Relay memory | Milliseconds |

## Adversaries and what stops them

| Adversary | Capability | Defence | Residual risk |
| --- | --- | --- | --- |
| Network attacker | Read/modify WSS or LAN traffic | TLS/WSS in cloud mode; Olm AEAD + Ed25519/ HMAC auth, replay guards; ciphertext-only relay | Local mode uses cleartext ws:// on the LAN, so metadata (sizes, timing, roles) is visible; content is still sealed |
| Relay operator (Cloudflare or laptop) | Sees all relayed frames, can drop them | Sees only ciphertext, public keys, pair id, timing. No message store, no queue, no keys | Traffic analysis: who talks, when, how much |
| Stranger with the QR | Scans/keeps a pairing code | Single-use, 10-minute expiry, rate-limited registration, two slots only | A code photographed before use can be redeemed first; the SAS code then mismatches and both people must re-pair |
| Third phone | Tries to join later | No slot, no discovery, signed/token auth on every socket, revoked devices refused | — |
| Thief with an unlocked phone | Has the running app | Lock on background, passphrase, biometrics, `FLAG_SECURE` | A phone unlocked *and* in an active private session is exposed |
| Thief with a locked phone | Has the device at rest | Keystore-backed encryption, Argon2id verifier, no chat at rest | Offline brute force of a weak passphrase; OS-level compromise |
| Malicious app on the same phone | Screen capture, accessibility, root | `FLAG_SECURE`, no exported components, no clipboard use for messages, no logs of content | Root/accessibility abuse is outside what any app can prevent |
| Attacker with a stolen recovery package | Has the blob | Argon2id (64 MiB, t=3) + XChaCha20-Poly1305 AEAD with AAD; 12+ character passphrase enforced | A weak passphrase is guessable; the package still yields no chat and no private key |
| Compromised peer device | Reads its own messages | That is the peer's own endpoint | Endpoint compromise is out of scope for any E2EE system |

## Explicit non-goals

- Hiding the app from Android settings, notifications, the microphone indicator or
  the foreground-service notification. The app is visible and compliant.
- Guaranteed physical memory erasure. A managed runtime (Dart GC, Android kernel)
  cannot promise zeroisation; the design minimises plaintext copies and drops
  references, and never persists chat.
- Anonymity against the relay operator: pair ids, device ids and connection times
  are visible metadata.
- Protection against a compromised operating system, root, or a malicious build of
  the app itself.
- Multi-device per person, groups, file transfer, or history — none exist.

## Metadata the relay holds

Cloud mode, SQLite: `pairs(pair_id, created_at)`,
`devices(pair_id, role, device_id, public_key, olm_key, registered_at)`,
`revocations(pair_id, device_id, revoked_at)`, `recovery_meta` only if a package is
registered, plus the invite hash and its expiry while an invitation is open.
No message rows, no ciphertext, no attachments, no transcripts.

Local mode: the same information in memory, deleted on shutdown or reset.

## Assumptions

1. Android Keystore and `flutter_secure_storage`'s Keystore-backed encryption
   behave as documented on the device.
2. vodozemac implements Olm correctly; this project has not audited it.
3. WebRTC's DTLS-SRTP protects media end to end between the two phones.
4. The user picks a non-trivial passphrase and keeps the recovery package offline.
5. The user compares the SAS code on both phones when asked.
