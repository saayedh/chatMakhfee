# Cryptography and wire protocol

This document describes the current source implementation after remediation pass 1.
It is not a cryptographic audit and must not be read as proof that the Android app
has compiled or that the protocol has passed interoperability testing.

No proprietary encryption primitive is implemented. The application uses
Vodozemac/Olm primitives for one-to-one message encryption and `@noble` packages
for relay-side signature and MAC verification.

## Libraries

| Purpose | Library | Version | Notes |
| --- | --- | --- | --- |
| 1:1 message encryption and ratchet | `flutter_vodozemac` / Vodozemac | `0.9.0` | Rust implementation via cargokit; native Android build still needs verification |
| Ed25519 signatures, SHA-256, HMAC (relays) | `@noble/curves`, `@noble/hashes` | `2.4.0` | Relay-side verification |
| Argon2id, XChaCha20-Poly1305 | `cryptography` / `cryptography_flutter` | `2.9.0` / `2.3.4` | Passphrase verifier and recovery package |
| SHA-256 for device IDs | `crypto` | `3.0.8` | Device ID derived from signing public key |
| At-rest storage | `flutter_secure_storage` | `11.2.0` | Platform-backed secure storage; per-use biometric key binding remains incomplete |

## Identity and device registration

A Vodozemac `Account` supplies long-term Ed25519 signing and Curve25519 identity
keys. Its pickled account state is encrypted before being stored using a random
secret kept in secure platform storage. The public Ed25519 key determines the
device identifier. The public Curve25519 Olm identity key is registered with the
pair record and must match the key presented in subsequent signed Hello frames.

The private account object is intended to be loaded only while the user is
unlocked. Lock teardown drops the application reference to the in-memory account
object. This is best-effort lifecycle hygiene, not guaranteed physical memory
zeroisation.

## Signed Hello and bootstrap keys

The canonical signed Hello payload includes the protocol and pair context,
device identifier, role, timestamp, nonce, Ed25519 identity and the Olm
Curve25519 identity plus one-time pre-key. Cloudflare and local relays verify the
signature and compare the presented Olm identity key with the key registered
for that device slot. This prevents an otherwise valid Ed25519 device from
silently substituting an unrelated Olm identity key during a later connection.

Role A creates the initial outbound Olm session and sends the first pre-key
message. Role B consumes that pre-key message to establish its corresponding
session. Once that bootstrap message has been processed, either participant can
send ordinary encrypted messages and call-signaling envelopes. The protocol
must still pass two-way device integration tests before use.

## Bilateral SAS verification

The SAS transcript is derived from the Olm-established shared secret and binds
the pair ID, session ID, both device IDs, both Ed25519 identities and both Olm
identity/bootstrap key sets. The SAS signal is exchanged inside the encrypted
Olm channel. Both users must explicitly approve the same transcript; the client
then sends an encrypted verification confirmation bound to the current session
and transcript. Chat messages and call signaling are gated until both local and
peer confirmation states are satisfied.

This is an application-specific protocol composition around Olm primitives. It
has not received independent protocol review. Do not treat the SAS workflow as
independently audited MITM protection until it has been reviewed and tested.

## Message encryption and wire encoding

The application envelope contains a sender Curve25519 key, Olm message type,
Olm ciphertext, message ID and timestamp. Chat and call-signaling payloads use
the same encrypted envelope; the relay only forwards ciphertext.

A critical encoding boundary exists between the library and the relay protocol:

- Vodozemac APIs expose key/signature bytes and Olm ciphertext in standard
  Base64-oriented representations.
- The `sp1` relay protocol validates unpadded Base64URL fields.
- The Flutter client therefore converts public-key and signature raw bytes to
  Base64URL for wire messages, and converts standard Base64 Olm ciphertext to
  Base64URL before relay transmission.
- Before calling Vodozemac decrypt/bootstrap APIs, the client converts the
  Base64URL ciphertext back to the standard Base64 representation expected by
  the library.
- Curve25519 public keys received from the wire are decoded to exactly 32 raw
  bytes and constructed from bytes, rather than passing a Base64URL string to a
  standard-Base64 parser.

The conversion helpers and Dart logic-check cases are present in source, but
could not be executed because Dart/Flutter are unavailable in the build
environment. This boundary remains a required compile and two-device test.

## Relay authentication

- Cloud and Local Hello frames use Ed25519 signatures over canonical JSON and
  a single-use nonce, checked against the registered signing public key.
- The Olm identity public key in Hello must equal the device slot's registered
  Olm public key.
- Local QR pairing uses a short-lived one-time challenge and an HMAC proof
  bound to the pair, challenge, joining device ID and public signing/Olm keys.
- Local bootstrap still uses HTTP/WS on the private LAN; the HMAC proof reduces
  direct invitation-token exposure but is not TLS and does not defeat an active
  man-in-the-middle on an untrusted LAN.
- Revocation requests are Ed25519-signed and scoped to the pair and requester.

## Passphrase, biometrics and recovery

The passphrase verifier uses Argon2id and is compared without storing the
plaintext passphrase. Failed-attempt counts and lock deadlines are persisted in
secure storage. `local_auth` supplies the biometric prompt, but its success is
not yet bound to a per-use Android Keystore operation that unwraps the Olm
pickle key. Consequently, this revision does not claim hardware-authenticated
key release for every unlock.

The recovery package uses Argon2id and XChaCha20-Poly1305. It contains pairing
membership metadata and public key information, not the prior private device
identity key, session ratchets or chat history. Restoring it is a membership
recovery step: a replacement device creates a new identity and requires peer
re-verification. It does not restore old conversations.

## Remaining limitations

1. This source has not been independently audited.
2. Flutter/Dart compilation and native Vodozemac Android build have not been
   run in this environment.
3. Local HTTP/WS transport is not TLS; use a trusted private LAN only.
4. Biometric UI success is not yet cryptographically bound to auth-per-use
   hardware key release.
5. The protocol composition and SAS transcript need independent review and
   two-physical-device tests.
6. Dart/managed-runtime memory cannot be guaranteed physically zeroised.
7. No offline queue or persistent chat history is intended; both clients must
   participate in an active session.
8. Local TURN is not bundled, ICE restart is not implemented, and real voice
   calling has not been tested on two Android devices.
