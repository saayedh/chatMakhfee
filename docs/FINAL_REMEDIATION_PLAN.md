# SecretPlay final remediation plan

This document distinguishes work already present in the repaired source from
work added for reproducible GitHub builds, and from security work that still
requires a platform-specific implementation or device testing.

## Completed in source (not a production security certification)

- Flutter app, Cloudflare Worker/Durable Object, local relay, shared crypto core,
  voice harness and project documentation are retained.
- Previous remediation adds bilateral verification gating, signed device
  metadata, separate Cloud/Local pair credentials, message-session expiry,
  in-memory-only relay behavior, and WebRTC ICE candidate buffering.
- Added GitHub Actions backend checks and Android debug APK workflow.
- Added signed tag-release workflow requiring four Android signing secrets.
- Added Windows Gradle-wrapper bootstrap, GitHub push/download/release, Android
  signing setup and source ZIP packaging helpers.
- Added source secret scanning before scripted Git push.
- Added release signing configuration that refuses to use the debug key.
- Added Gradle wrapper distribution checksum pin.
- Updated project build documentation to match the CI toolchain.

## Still open / not certified

1. Android biometric success is not yet proven to gate access through an
   authentication-required hardware-backed key for the Olm identity pickle.
2. Local pairing transport remains HTTP/WS in this source revision; there is no
   TLS certificate pinning implementation for the laptop relay.
3. WebRTC ICE restart/re-negotiation is not implemented as a verified recovery
   path.
4. A local Coturn service is not bundled or validated; restrictive hotspot or
   client-isolation topologies may prevent audio connectivity.
5. `FLAG_SECURE` remains Activity-wide, not restricted to private screens.
6. Full identity recovery is not implemented: the current recovery format is
   Pair Membership Recovery and does not restore the prior private Olm identity.
7. No two-device Android hardware test has been run in this environment.
8. No production Cloudflare Worker deployment has been performed.
9. No independent security audit has been performed.

## Release gate

Do not use this app for sensitive conversations until Flutter/Rust compilation,
cryptographic integration tests, Android lifecycle tests, two-device Cloud/LAN
pairing, real WebRTC voice tests, recovery/revocation tests, and a focused mobile
security review have passed.
