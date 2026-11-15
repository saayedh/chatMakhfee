# SecretPlay

A private, two-device messenger for Android with a small game in front of it.
One authorised phone per person, end-to-end encrypted text and voice, **no stored
chat history**, immediate locking, encrypted recovery, and two independent
relays: Cloudflare (Workers + SQLite Durable Objects) and a Windows laptop
(`local_server`, for when there is no Internet at all).

This repository is a development implementation, not a security-audited release.
The shared relays and protocol core include automated tests; the Android client
and native cryptography integration still require Flutter/Rust toolchain builds
and two-device testing. See the current [remediation report](docs/REMEDIATION_REPORT.md)
for the exact items changed and the checks that remain unverified.

---

## Layout

```
android_app/      Flutter app (game shell + private shell), Kotlin host code
cloudflare/       Worker + PairRoom Durable Object relay (free-plan only)
local_server/     Laptop relay: Fastify + ws, in-memory, offline-capable
crypto_core/      Shared TypeScript protocol: frames, auth, pairing, recovery
scripts/          Windows BAT + PowerShell automation (APK download, Git push, package, local run/deploy)
docs/             Architecture, threat model, crypto, deployment, tests
```

## Quick start

### Optional backend tests and type checks (run locally on your laptop; not part of GitHub Actions)

```bat
cd crypto_core  && npm ci && npm test && npm run typecheck
cd ..\local_server  && npm ci && npm test && npm run typecheck
cd ..\cloudflare    && npm ci && npm test && npm run typecheck

# Required Node.js: >= 22.18.0. Install crypto_core first because both relays
# import the shared TypeScript sources and resolve its pinned @noble packages.
cd ..\cloudflare    && npx wrangler deploy --dry-run --outdir=.wrangler\dry-run
```

### Pure-Dart logic checks (works without Flutter)

```bat
cd android_app && dart tool\logic_check.dart
```

### Local / offline mode

```bat
scripts\install-local.bat    :: once, with Internet
scripts\run-local.bat        :: anytime after that, no Internet needed
scripts\stop-local.bat
```

The relay prints the laptop's LAN IPv4 addresses, a single-use QR, and a console
admin token. Phones join the same Wi-Fi or the Windows Mobile Hotspot, then scan
the QR from **Private → Network & pairing → Local**.

### Cloud mode

```bat
scripts\deploy-cloudflare.bat
```

Requires `npx wrangler login` first (the script checks and tells you). It runs
the tests, bundles with `--dry-run`, then deploys. Paste the printed
`https://secretplay.<subdomain>.workers.dev` into the app's Cloud pairing screen.

### Android APK and GitHub Actions

The configured GitHub repository is:

https://github.com/saayedh/chatMakhfee

GitHub Actions has exactly one job: build the Android debug APK and upload it as the `SecretPlay-Android-APK` artifact. It runs after a push to `main` or a manual `workflow_dispatch` request. It does not run backend tests, deploy Cloudflare, configure secrets, start the laptop server, or publish GitHub Releases.

Push source from your laptop:

```bat
scripts\github-push.bat
```

Download the latest successful APK artifact:

```bat
scripts\github-build-download.bat
```

The downloaded file is saved to `artifacts\github-apk\SecretPlay-Android.apk`.

The workflow builds a debug APK for testing. It does not use release-signing secrets. GitHub-hosted runners may generate different debug signing certificates between runs, so Android can require uninstalling an older debug build before installing a newer one.

All Cloudflare deployment, local server operation, TURN configuration, and other backend administration remain manual tasks on your laptop using the scripts and guides in this repository. See [docs/GITHUB_SETUP.md](docs/GITHUB_SETUP.md).

---

## What it does and does not do

- Exactly two device slots. No registration, discovery, contact sync, ads,
  analytics or third-party tracking.
- Messages are Olm (Double Ratchet) encrypted. The relay sees ciphertext and
  public keys only, forwards in memory, and has **no** message table, queue or
  offline delivery.
- A session exists only while both devices are connected: heartbeat 5 s, timeout
  20 s (configurable in `.env` / `wrangler.jsonc`). Ending or locking either side
  ends it for both.
- Voice is WebRTC peer-to-peer with DTLS-SRTP; the relay only carries encrypted
  signalling. TURN is optional, off by default, and documented as billable.
- The private area has an immediate lock overlay and native lifecycle hooks.
  Device-specific lifecycle behavior still needs physical Android verification.
  `FLAG_SECURE` is currently enabled at the Activity level, so it also affects
  the game UI, not only private screens.
- No guaranteed physical memory erasure is possible in a managed runtime. The app
  minimises plaintext copies, keeps messages in RAM only, and drops them on lock.

## Documentation

| Document | Contents |
| --- | --- |
| [docs/AUDIT.md](docs/AUDIT.md) | Security/architecture review: fixed and open findings |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Components, protocol, session lifecycle |
| [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) | Assets, adversaries, what is and is not defended |
| [docs/CRYPTOGRAPHY.md](docs/CRYPTOGRAPHY.md) | Libraries, key use, session-only ratchet policy |
| [docs/LOCAL_MODE.md](docs/LOCAL_MODE.md) | Hotspot setup, QR pairing, LAN calls, firewall |
| [docs/CLOUDFLARE_DEPLOYMENT.md](docs/CLOUDFLARE_DEPLOYMENT.md) | Deploy, free-plan limits, TURN, cost control |
| [docs/ANDROID_BUILD.md](docs/ANDROID_BUILD.md) | Toolchain, build, install, signing, troubleshooting |
| [docs/GITHUB_SETUP.md](docs/GITHUB_SETUP.md) | Push to the configured private repo and download the APK-only workflow artifact |
| [docs/RECOVERY.md](docs/RECOVERY.md) | Recovery package format, new-device approval |
| [docs/SECURITY_TESTS.md](docs/SECURITY_TESTS.md) | Automated suites + manual device plan |
| [docs/FINAL_BUILD_REPORT.md](docs/FINAL_BUILD_REPORT.md) | Build/CI deliverables, checks performed and remaining limitations |

## Feature status (source review; not a release certification)

| Feature | Current status |
| --- | --- |
| Shared TypeScript protocol and relays | Source implemented; syntax checked, but project test suites and typechecks were not rerun in this environment |
| Signed Hello / registered Olm identity binding | Source updated; cryptographic integration still needs tests with dependencies installed |
| Bilateral SAS gate | Source updated to gate messages and calls; end-to-end MITM and two-device verification tests remain required |
| Session-only messaging | No persistent message/history schema; real device and restart tests remain required |
| Cloudflare backend | Source present; no Worker dry-run or deployment verified in this revision |
| Laptop local server | Source present; Windows scripts and trusted-LAN behavior not executed here |
| Cloud-to-local fallback | Probes an existing Local pairing after Cloud failure; ends the old session and requires re-authentication, not seamless failover |
| WebRTC voice | Source present; ICE configuration and candidate buffering improved; physical calls, audio routes and TURN fallback unverified |
| Immediate lock | Source path and native hooks present; lifecycle behavior not verified on Android hardware |
| Biometric integration | API shape updated; biometric prompt is not yet cryptographically bound to per-use Keystore key access |
| Encrypted recovery | Recovery metadata package; does not restore chat or the old private Olm identity |
| APK build | Not built in the available environment |
| Security audit | Not performed; project is not approved for production or sensitive use |

See [docs/REMEDIATION_REPORT.md](docs/REMEDIATION_REPORT.md), [docs/FINAL_REMEDIATION_PLAN.md](docs/FINAL_REMEDIATION_PLAN.md), and [docs/FINAL_BUILD_REPORT.md](docs/FINAL_BUILD_REPORT.md) for exact modifications, verification limits and remaining risks.

## Security notes

- No hand-rolled cryptography. Olm/vodozemac, Ed25519 (@noble), Argon2id and
  XChaCha20-Poly1305 (`cryptography`) do the work.
- Using reviewed libraries is not the same as an audit. This project has not been
  audited.
- Voice media path depends on WebRTC's own DTLS-SRTP; a TURN relay forwards
  encrypted packets without terminating endpoint encryption, but a compromised
  endpoint is out of scope. See [SECURITY.md](SECURITY.md).

## Licence

Personal project. No licence is granted for redistribution.
