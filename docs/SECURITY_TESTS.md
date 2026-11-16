# Security tests

This document separates checks actually run on the repaired source from tests that still require a provisioned development machine or physical Android devices. Do not treat a source file existing or a mock test passing as proof of a real Android cryptographic or voice feature.

## Checks performed on the repaired source in the current environment

| Check | Result |
|---|---|
| Node TypeScript syntax parser (`node --experimental-strip-types --check`) | 43 TypeScript source/test files parsed without syntax errors at the time of the check |
| Strict JSON parse | 12 JSON files parsed successfully |
| Android XML parse | 9 XML files parsed successfully |

These are syntax/format checks only. They do not establish TypeScript type correctness, runtime behavior, Flutter compilation, cryptographic interoperability, or security.

## Not executed in this environment

| Suite / test | Why it was not run |
|---|---|
| `crypto_core` npm tests and typecheck | npm dependency installation blocked by registry DNS/network timeout; Node 22.16.0 is below required 22.18.0 |
| `local_server` npm tests and typecheck | same dependency and Node limitations |
| `cloudflare` npm tests, typecheck and Wrangler dry run | same dependency and Node limitations; no Cloudflare deployment |
| Dart / Flutter tests and analyzer | Flutter/Dart SDK unavailable |
| Vodozemac FFI compilation | Flutter/Rust native build toolchain unavailable |
| APK build | Flutter/Android SDK/JDK build environment unavailable |
| Physical Android lifecycle, LAN and WebRTC calls | requires two Android phones and a laptop/router test network |

## Required commands on a supported Windows development machine

Install Node.js 22.18.0+, Flutter 3.44+, Dart 3.12+, Android SDK 36, JDK 17 and Rust. Then run:

```bat
cd crypto_core && npm ci && npm test && npm run typecheck
cd ..\local_server && npm ci && npm test && npm run typecheck
cd ..\cloudflare && npm ci && npm test && npm run typecheck
cd ..\cloudflare && npx wrangler deploy --dry-run
cd ..\android_app && flutter pub get && flutter analyze && flutter test
cd ..\android_app && flutter build apk --debug
```

## Manual two-device security plan

Run `android_app/test/manual/DEVICE_TEST_PLAN.md` on two physical Android devices. At minimum verify:

1. Pairing and exact two-device limit.
2. A and B each initiating the first ordinary message after the common handshake.
3. SAS mismatch blocks messages and calls.
4. Both users must approve the same current-session code.
5. Modified Hello keys and signature tampering are rejected.
6. Leaving or locking either device terminates the session and stops microphone capture.
7. No old session resumes after app restart.
8. No offline message is queued.
9. Cloud outage selects an already paired Local relay only after a successful local health probe; the user must re-authenticate and start a new session.
10. Local pairing challenge expiry, one-use behavior and LAN limitations.
11. Direct LAN WebRTC call; test a hotspot/router with client isolation and document whether local TURN is needed.
12. TURN expiry, failure and disabled configuration.
13. Backup restores only recovery metadata, never message history or previous session keys.
14. Device revocation and new-device approval.

## Known security gaps

- Local LAN HTTP/WS is still cleartext. The invitation itself is no longer sent in the registration body, but local transport is not protected against an active LAN attacker. Use a trusted private LAN only.
- Biometric success is not yet bound to a per-use Android Keystore key operation protecting the Olm pickle.
- The Vodozemac integration has not been compiled or exercised here.
- No local Coturn service is bundled; some hotspot/router topologies can prevent direct peer-to-peer audio.
- Automatic ICE restart and seamless active-session Cloud-to-Local migration are not implemented.
- Managed-runtime memory cleanup is best effort and cannot guarantee physical erasure.
- This project has not undergone an independent security audit.
