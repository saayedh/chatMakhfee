# CI TypeScript typecheck fix — signed Hello Olm keys

## Symptom

GitHub Actions failed in `local_server` with:

- `TS18048: hello.olm is possibly undefined`
- `TS2322: OlmKeys | undefined is not assignable to OlmKeys`

## Cause

`HelloFrame` is a union where `olm` is mandatory for `auth.kind === 'signed'`, but TypeScript does not reliably narrow the nested `olm` property after checking the nested discriminant `hello.auth.kind`. The protocol parser already rejects signed Hello frames without `olm`, but the server handlers did not bind that runtime invariant to a local non-optional variable.

## Change

Both the laptop relay and Cloudflare Durable Object now explicitly read `const olm = hello.olm`, reject the connection if it is absent, and use the narrowed `olm` value for identity comparison, signature verification, and session attachment. This is a real runtime validation, not a type assertion or non-null suppression.

Files changed:

- `local_server/src/server.ts`
- `cloudflare/src/durable_objects/pair_room.ts`
- `crypto_core/test/frames.test.ts`

A dedicated parser regression test verifies that a signed Hello without Olm bootstrap material is rejected.

## Verification status

The source-level fix is applied. Re-run the exact CI commands (`npm run typecheck` in `local_server` and `cloudflare`, plus `npm test` in `crypto_core`) in GitHub Actions. This build environment does not have the project dependencies installed and uses Node.js 22.16.0, below the repository's declared minimum of 22.18.0, so a full local TypeScript check is not claimed here.


## Current CI scope

The current `.github/workflows/android-apk.yml` is intentionally APK-only. It no longer runs TypeScript backend typechecks or Cloudflare/Wrangler commands. Run the local-server and Cloudflare TypeScript checks manually on the laptop when modifying those components; these checks are outside the GitHub APK workflow by design.
