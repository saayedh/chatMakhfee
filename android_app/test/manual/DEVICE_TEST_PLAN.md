# SecretPlay — physical-device test plan

These checks require **two real Android phones** (and a Windows laptop for local
mode). They were **not** executed while this project was written, because the
build machine had no Flutter SDK, no Android SDK, no Rust toolchain and no
attached devices. Nothing in this file may be reported as "passed" until someone
runs it on hardware.

Record for each run: date, phone models, Android versions, app build, network.

---

## 0. Install

1. Build the APK (`scripts\build-android.bat`) and install it on both phones
   (`adb install -r android_app\build\app\outputs\flutter-apk\app-debug.apk`).
2. Confirm the app launches into the game shell and the private area asks for a
   passphrase the first time.

## 1. Pairing (cloud mode)

1. On phone A: Private → Network & pairing → Cloud → paste the Worker URL →
   **Create pair and show QR**.
2. On phone B: Network & pairing → **Scan the other phone** → scan A's QR.
3. Both phones show a six-digit code (Verify devices). The codes MUST match.
4. Expect: A shows role A, B shows role B; a third phone scanning the same QR
   fails with "expired or already used".

**Pass criteria:** second scan is refused; codes match; pair holds exactly two
devices.

## 2. Session-only messaging

1. Both phones: Private → chat → Connect.
2. Send messages both ways; confirm delivery and ordering.
3. On A, press Home. Expect: A locks immediately; B receives the end and locks.
4. Reopen A, unlock, reconnect. The chat list must be **empty**.
5. Kill the relay (or turn off Wi-Fi) mid-session. Both phones lock within the
   timeout (20 s default) and show a timeout reason.

**Pass criteria:** no message survives a lock; both devices end together; no
"missed messages" ever appear.

## 3. Tampering and replay

1. With a debugging proxy or a patched test build, flip one byte in a `msg`
   cipher body. Expect: the receiver drops it and shows
   "A message could not be authenticated and was dropped." — no crash.
2. Re-send a previously captured `msg` frame with the same `id`. Expect: the
   relay rejects it (replay guard) and the session continues.

## 4. Immediate locking

1. Open the private chat, then open Recents. Expect: the thumbnail shows the lock
   screen, not the chat (`FLAG_SECURE` + overlay).
2. Turn the screen off and on. Expect: passphrase required again.
3. Trigger the biometric prompt from the lock screen, cancel it. Expect: the app
   stays locked, and cancelling does **not** end a session that was already ended
   by the lock.
4. Background the app for <1 s and return (grace window). Expect: still locked,
   but no false "connection lost" claim on the other phone unless the lock fired.

## 5. Voice call (cloud mode)

1. Both phones on mobile data or different Wi-Fi networks; TURN **disabled**.
2. A: chat → call icon → Start call. B: Accept.
3. Expect: audio both ways, Android microphone indicator visible, ongoing
   notification on both phones, timer running.
4. Toggle mute, speaker, and a Bluetooth headset. Note which routes work on each
   phone model.
5. End the call on A. Expect: B ends too, microphone released, notification gone.
6. Put A in the background during a call. Expect: the call ends (a locked app
   must not hold the microphone).

**Pass criteria:** two-way audio, correct audio routing, mic released on end and
on lock. If the call cannot connect on carrier networks, that is the documented
TURN-off limitation — retest with TURN enabled.

## 6. Local / offline mode

1. Laptop: `scripts\install-local.bat` once with Internet, then disconnect the
   laptop from the Internet entirely.
2. Laptop: Windows Mobile Hotspot on (or join both phones to the same router with
   no WAN).
3. `scripts\run-local.bat`. Note the printed LAN URL and QR.
4. Phones: join the hotspot, open SecretPlay → Network & pairing → Local →
   **Scan the laptop QR** on both phones.
5. Chat both ways; then a voice call. Expect: direct LAN audio, no external
   STUN/TURN, works with the laptop offline.
6. Stop the relay (`stop-local.bat`). Expect: both phones lock.

**Pass criteria:** chat and call work with no Internet; nothing reaches a public
endpoint.

## 7. Recovery

1. Phone B: Recovery → set a passphrase → **Create encrypted package** → copy.
2. Wipe B (Security → Forget this device) or use a third phone.
3. Paste the package, enter the passphrase. Expect: the pair id/role/peer key are
   restored, but **no messages** appear and the identity is new.
4. Connect. Expect: the other phone sees an unknown identity and the SAS codes do
   not match until it explicitly verifies the new device.

**Pass criteria:** package opens only with the right passphrase; no chat content
is recoverable; the peer must approve the new identity.

## 8. Revocation

1. Cloud mode: A → Security → **Revoke the other device**. Expect: B is dropped
   mid-session and cannot reconnect (403 `device_revoked`).
2. Local mode: use the documented admin command from the laptop console, then
   confirm B is rejected.

## 9. Session recovery after restart

1. Active session, then force-stop the app on A.
2. Reopen on both. Expect: no session is restored; A must unlock and reconnect;
   no queued messages are delivered.

---

## What "passed" means

Only mark a section passed if every observable step above happened on hardware.
Anything else stays "implemented, not physically tested" in the feature table.
