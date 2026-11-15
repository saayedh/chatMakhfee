# SecretPlay — Remediation Report

**Revision:** source remediation pass 1  
**Scope:** uploaded `chatMakhfe.zip` source tree  
**Status:** development source improved; **not approved for production or sensitive real-world use**.

This report distinguishes source changes from tests that were actually executable in the current environment. It does not claim a full build, cryptographic audit, Cloudflare deployment, or two-phone verification.

## 1. Environment and verification limits

The following tools were available:

- Node.js `22.16.0`; the repository requires `>=22.18.0`.
- npm `10.9.2`.
- Node's built-in TypeScript syntax stripping/parser.

The following were unavailable or could not be completed:

- Flutter SDK and Dart SDK.
- Android SDK / Gradle build environment.
- Rust toolchain for the `flutter_vodozemac` native integration.
- Node `22.18.0+` required by the repository.
- Successful access to the npm registry; dependency installation was blocked by DNS/network timeout.
- Cloudflare account authentication and deployment access.
- Two physical Android devices for real pairing, lifecycle, LAN and audio tests.

Consequently, no APK was built, no Flutter analyzer/test suite ran, no TypeScript typecheck or project test suite was independently completed, no Worker was deployed, and no real WebRTC call was placed. The checks listed in section 5 are narrower and must not be confused with those unavailable tests.

## 2. Changes made

### A. Android lifecycle and lock path

- Added `android_app/lib/sessions/session_lock_sink.dart` and wired it from `android_app/lib/app/app.dart`.
- The lock sink stops WebRTC/media first, then closes the relay session, clears call-signal and transient session state, unloads the in-memory Olm account object and invalidates the identity provider.
- Changed the configured lock grace window to zero and made the private lock cover visible before asynchronous teardown.
- Kept Flutter lifecycle handling from treating every `inactive` event as a real background event, because biometric and permission system UI can temporarily cause `inactive`; native Android lifecycle signals remain important and require device testing.
- Reset the intermediate passphrase step on lock/background events.
- Persisted failed-passphrase attempt count and lock deadline in secure storage so process restart does not reset the limiter.

**Remaining limitation:** `local_auth` success is still a UI-level biometric gate. The stored Olm pickle key is not yet wrapped in a per-use Android Keystore key whose operation itself requires biometric authentication. This is weaker than the intended hardware-backed, auth-per-use design.

### B. Pair verification and session protocol

- Added Olm identity and one-time pre-key material to the signed Hello payload in `crypto_core`.
- Updated frame validation and signature verification so the signed Hello covers those public Olm bootstrap keys.
- Updated Cloudflare and local relays to reject a signed Hello whose long-term Olm identity key differs from the value registered during pairing.
- Persisted the peer identity material through Cloudflare Durable Object WebSocket attachments.
- Bound the client SAS transcript to the pair ID, session ID, both device IDs, both Ed25519 signing identities, and both Olm key sets.
- Added bilateral local approval and peer confirmation; chat sending and call signaling are gated until both devices approve the same transcript.
- Added encrypted `verify_ok` signaling bound to the current session ID and SAS transcript.
- Kept the A-side pre-key bootstrap as the one initial Olm session-establishment message; after B consumes it, either device can send regular encrypted chat and signaling.
- Changed outbound status from an untrue `delivered` state to `sent`, because relay acceptance is not a delivery receipt.
- Normalized the wire encoding boundary: Vodozemac key/signature bytes and Olm ciphertext use the library’s standard Base64 representation internally, while the `sp1` relay protocol uses unpadded Base64URL. Added explicit byte-level conversion helpers and strict 32-byte Curve25519 key parsing so the Flutter client and TypeScript relays agree on the wire format.
- Made `markPeerVerified()` return whether the approval signal was actually sent, so the verification UI does not falsely lock its button after a failed send.

**Remaining limitation:** This is a custom application protocol integration around Olm primitives, not a claim of a complete independently audited Signal/Matrix protocol implementation. The Dart/Vodozemac APIs and cryptographic interoperability must still be compiled and tested. Existing pair registrations created before mandatory Olm identity registration may need to be removed and paired again.

### C. Local QR pairing bootstrap

- Normalized the malformed `android_app/lib/networking/pairing_service.dart` source into valid Dart line structure; the uploaded file had been encoded as a single line containing literal `\\n` sequences.
- Replaced direct transmission of the raw local invitation in the registration HTTP body with a short-lived, single-use challenge and an HMAC proof bound to pair ID, challenge, device ID, Ed25519 public key and Olm public key.
- Added `GET /v1/pair/challenge` to the local server. Challenges expire after 30 seconds, are one-use, are pair-bound and are rate-limited.
- The challenge is consumed even when a proof fails, preventing repeated attempts against the same challenge.
- The Android client checks that the response pair ID and WebSocket URL match the QR payload it scanned.
- Strictly validates local pairing QR URL shape and private-network host/port constraints.

**Remaining limitation:** The local bootstrap and local WebSocket are still HTTP/WS, not TLS. The HMAC proof means the raw QR invitation is not sent in the registration body and binds the proof to the joining device keys, but it does not authenticate the laptop against an active man-in-the-middle on an untrusted LAN or provide transport confidentiality for metadata. Use only a trusted private LAN until pinned local TLS is implemented and tested.

### D. Cloud / Local profile isolation and mode selection

- Namespaced pairing credentials for Cloud and Local so switching modes does not combine a Cloud endpoint with Local pair credentials.
- Kept revocation operations scoped to the selected mode.
- Added a startup / post-network-failure probe that can select an already paired local relay after Cloud becomes unreachable.
- The fallback locks and ends the current session; it does not migrate or resume the old session. A fresh user authentication and new session are required.

**Remaining limitation:** This is not a seamless active-session failover. It also depends on both phones and the laptop being on the same functioning LAN or laptop hotspot. The OS network and hotspot isolation behavior must be verified on the actual devices.

### E. WebRTC and TURN integration

- Added Cloud `/v1/info` ICE configuration retrieval, including optional short-lived TURN entries when configured.
- Local mode reads local relay ICE configuration; an empty list means host candidates only and does not silently call public STUN/TURN services.
- Added a bounded ICE candidate queue so candidates arriving before remote SDP or before the callee accepts an offer are not immediately discarded.
- Clear pending call candidates and signal buffers during teardown.
- The UI message for disconnected ICE no longer claims a reconnect is underway; it explains that WebRTC may recover briefly and that the user may need to end/restart the call.
- Corrected the voice harness cloud test script to reference the existing relay-call test file.

**Remaining limitations:** No real call has been tested. No automatic ICE restart/re-negotiation is implemented. A local Coturn service is not bundled or installed; if the hotspot/router prevents direct LAN peer connectivity, audio may fail. Bluetooth and full audio-route behavior also need physical testing. TURN is disabled by default and may incur Cloudflare charges if enabled beyond any applicable allowance.

### F. Dependency and Windows scripts

- Updated `scripts/install-local.bat` to install `crypto_core` dependencies before local server dependencies.
- Updated `scripts/deploy-cloudflare.bat` to install shared crypto dependencies before Worker bundling/typecheck/deployment.
- Added explicit Node minimum-version checking (`>=22.18.0`) to installation, local run and deployment scripts.
- Updated `scripts/run-local.bat` to check for the shared crypto dependency before starting.
- Corrected the voice harness `test:cloud` target.

**Remaining limitation:** Windows batch scripts were reviewed as text but could not be executed in this Linux environment. A clean Windows install/run/deploy test remains required.

## 3. Important known gaps

1. **No production approval:** source changes are not a security audit.
2. **Flutter compilation unavailable:** `local_auth` was updated to the documented 3.x method shape, but Dart analyzer/build was not run.
3. **Vodozemac FFI unverified:** exact package API compatibility and native Rust build are still unverified.
4. **Biometric/key binding incomplete:** biometric UI success does not yet unlock the Olm pickle through an auth-per-use hardware-backed key.
5. **Local transport not TLS:** local HTTP/WS is suitable only for a trusted private LAN in this revision; active LAN adversaries remain a risk.
6. **No local TURN bundle:** peer-to-peer LAN media can fail under client isolation or restrictive network routing.
7. **No live call recovery:** ICE restart is not implemented.
8. **No physical-device tests:** lifecycle lock, Android foreground microphone service, audio routing, LAN pairing and voice media have not been run on phones.
9. **Recovery is membership metadata recovery:** it does not preserve the previous private Olm identity key or chat content. Device replacement requires a new identity and peer re-verification; the full replacement/revocation workflow still needs end-to-end testing.
10. **`FLAG_SECURE` is Activity-wide:** it also affects the game screen, not only the private area.
11. **Memory erasure is best effort:** Dart/managed runtime and OS memory behavior do not allow a guarantee that every physical copy is erased.
12. **No automatic transparent failover:** Cloud loss terminates the current session; Local mode may be selected after a successful probe and requires re-authentication.

## 4. Key files changed

- `android_app/lib/app/app.dart`
- `android_app/lib/app/providers.dart`
- `android_app/lib/authentication/auth_service.dart`
- `android_app/lib/authentication/lock_controller.dart`
- `android_app/lib/authentication/passphrase_screen.dart`
- `android_app/lib/core/rate_limiter.dart`
- `android_app/lib/cryptography/olm_service.dart`
- `android_app/lib/networking/device_verification_screen.dart`
- `android_app/lib/networking/pairing_service.dart`
- `android_app/lib/networking/protocol.dart` (Base64URL / standard Base64 boundary helpers)
- `android_app/lib/sessions/session_controller.dart`
- `android_app/lib/sessions/session_lock_sink.dart`
- `android_app/lib/voice/call_controller.dart`
- `android_app/lib/voice/call_signals.dart`
- `crypto_core/src/auth.ts`
- `crypto_core/src/frames.ts`
- `crypto_core/test/auth.test.ts`
- `crypto_core/test/frames.test.ts`
- `android_app/tool/logic_check.dart` (encoding boundary test cases)
- `local_server/src/server.ts`
- `local_server/test/pairing.test.ts`
- `local_server/test/relay.test.ts`
- `local_server/test/support/relay.ts`
- `cloudflare/src/**` and `cloudflare/tests/**` (registered Olm identity validation / attachment changes)
- Windows scripts and project documentation.

## 5. Checks actually performed on the repaired source

| Check | Result |
|---|---|
| Node TypeScript syntax parser (`node --experimental-strip-types --check`) | 43 TypeScript files parsed without syntax errors at the time of the check |
| Strict JSON parsing of repository `.json` files | 11 files parsed successfully |
| XML parsing of Android XML files | 15 XML files parsed successfully |
| `npm test` / TypeScript typecheck | Not completed: dependency install was blocked and Node was below repository minimum |
| Flutter analyze / Dart tests | Not run: Flutter/Dart SDK unavailable |
| Android APK build | Not run: Flutter/Android/Rust build toolchain unavailable |
| Wrangler dry-run / deploy | Not run: project dependencies unavailable; Cloudflare account not connected |
| LAN and WebRTC phone tests | Not run: no two physical Android devices |

The TypeScript parser check validates syntax only; it does not replace TypeScript typechecking or test execution. The Base64URL interoperability cases were added to the Dart logic-check harness but could not be executed without Dart. Re-run all checks after installing dependencies on a supported development machine.

## 6. Required next validation on the owner's Windows machine

Use Node.js `22.18.0+`, Flutter `3.38+`, Dart `3.10+`, Android SDK 36, JDK 17 and Rust. Then run:

```bat
cd crypto_core && npm ci && npm test && npm run typecheck
cd ..\local_server && npm ci && npm test && npm run typecheck
cd ..\cloudflare && npm ci && npm test && npm run typecheck
cd ..\cloudflare && npx wrangler deploy --dry-run
cd ..\android_app && flutter pub get && flutter analyze && flutter test
cd ..\android_app && flutter build apk --debug
```

After that, pair two real Android devices in both Cloud and Local modes. Test lock, biometric cancel, invalid SAS, both directions of first message, call initiation from both sides, microphone and speaker, no Internet with laptop hotspot, router client isolation, restart, recovery and revocation. Do not use the application for sensitive communication until these tests pass and an independent mobile security review is complete.
