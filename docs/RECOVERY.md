# Encrypted recovery

Recovery restores **which pair to rejoin** — never chat, never keys to old
messages, never a trusted identity.

## What the package contains

Canonical JSON, sealed:

```jsonc
{ "pairId":"pair-...", "role":"A", "oldDeviceId":"d_...",
  "oldIdentityPublicKey":"...", "peerDeviceId":"d_...", "peerPublicKey":"...",
  "createdAt":1731600000000, "recoveryId":"r_...", "label":"Device A" }
```

Only public keys and membership metadata. It contains **no** private key, no Olm
pickle, no messages, no session state, no media, no call data. The identity key in
the package is informational: the new device generates a *new* identity.

## Container format

```jsonc
{ "v":1, "kind":"sp1-recovery-sealed",
  "kdf":{ "name":"argon2id", "m":65536, "t":3, "p":1, "dkLen":32 },
  "salt":"<b64, 16 bytes>", "nonce":"<b64, 24 bytes>",
  "aad":"secretplay.recovery.v1",
  "ct":"<b64, ciphertext||tag>" }
```

- Key: Argon2id over the passphrase with the package salt (64 MiB, 3 passes).
- Cipher: XChaCha20-Poly1305, AAD `secretplay.recovery.v1|v1`.
- On read, KDF parameters are bounded (8 MiB ≤ m ≤ 1 GiB, salt 16 bytes, nonce 24
  bytes) so a malicious package cannot exhaust memory or smuggle a weaker KDF.
- Wrong passphrase and a modified package are indistinguishable: both fail AEAD.
- The format is byte-compatible with `crypto_core/src/recovery.ts`, so the same
  package can be inspected from the command line.

## Create a package (old device)

1. **Private → Recovery.**
2. Choose a recovery passphrase of at least 12 characters. It is independent of
   your unlock passphrase; use a different one.
3. **Create encrypted package**, then **Copy package**.
4. Store it offline: a password manager entry, or printed and kept with your
   documents. It is useless without the passphrase and dangerous to publish.

## Restore (new device)

1. Install SecretPlay, set a lock passphrase.
2. **Recovery → paste the package → enter the recovery passphrase → Restore.**
3. The app restores `pairId`, `role`, the peer's device id and public key.
4. Connect. The other phone will see an unfamiliar identity. Compare the SAS code;
   it will **not** match until the other person explicitly verifies the new device.
5. If the old device still holds a slot, revoke it (Security → Revoke the other
   device) so the slot can be filled again.

## Guarantees and non-guarantees

| Guarantee | Detail |
| --- | --- |
| No chat recovery | Impossible by construction: no message store exists anywhere |
| No key recovery | The package holds public keys only; old ratchets died with the session |
| Fresh identity | The new device creates its own Olm account and device id |
| Explicit approval | The peer must verify the new device; a backup never auto-trusts |
| Revocable old device | Signed revocation through the Worker; local mode via the admin token |
| Offline-safe | Nothing about recovery contacts the relay until you connect |

Not guaranteed: that a stolen package is harmless if the passphrase is weak. Treat
the passphrase as the only lock on that file.

## If you lose everything

Both phones wiped and no package: there is nothing to recover, by design. Pair
again from scratch (create a new pair, scan the QR on the other phone). Historical
messages are gone and were never stored anywhere.
