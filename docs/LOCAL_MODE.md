# Local (offline) mode

The laptop becomes the relay. No Cloudflare, no DNS, no STUN/TURN, no Internet —
just a shared network between the laptop and the two phones.

## 1. One-time install (needs Internet)

```bat
scripts\install-local.bat
```

It checks Node.js (22.18+), runs `npm ci` in `local_server`, copies
`.env.example` to `.env`, and runs the relay tests. After this succeeds the laptop
can be offline forever and `run-local.bat` still works.

## 2. Network: Windows Mobile Hotspot (recommended)

No router and no Internet required.

1. **Settings → Network & internet → Mobile hotspot → On.**
2. Leave the band on **2.4 GHz** if either phone is older; 5 GHz is fine for
   modern phones.
3. Connect both phones to the hotspot SSID.
4. The laptop's hotspot address is usually `192.168.137.1`.
5. If phones cannot connect, allow **Node.js** through Windows Defender Firewall on
   **private** networks only:

```bat
netsh advfirewall firewall add rule name="SecretPlay local relay" dir=in action=allow program="%ProgramFiles%\nodejs\node.exe" profile=private
```

(Remove it later with `netsh advfirewall firewall delete rule name="SecretPlay local relay"`.)

**Do not** use the deprecated `netsh wlan set hostednetwork` commands; they do not
work on current Windows 10/11 drivers.

Alternative: put the laptop and both phones on the same home Wi-Fi router. Router
"client isolation" / "AP isolation" must be off, or the phones cannot reach the
laptop.

## 3. Start the relay

```bat
scripts\run-local.bat
```

It prints:

- every private IPv4 with its interface name, and the port (`8787` default);
- the pair id and which slot the next phone takes (A or B, never more);
- a QR code containing the local HTTP + WS URLs and a one-time invitation;
- a console-only admin token;
- the hotspot checklist and firewall hint.

The relay writes nothing except `.secretplay.pid`. Messages are never stored.

## 4. Pair both phones

On each phone: **Private → Network & pairing → Local → Scan the laptop QR**.

- First phone takes slot A, second takes slot B.
- The invitation rotates after each successful registration and expires after
  10 minutes.
- The relay prints `PAIRING COMPLETE` when both slots are filled. A third scan
  fails: there is no third slot.

Both phones then compare the six-digit SAS code under **Verify devices**.

## 5. Chat and call

- Open the private area, unlock, then **chat → Connect**. A session exists only
  while both phones are connected.
- Press the call icon, accept on the other phone. Audio goes phone-to-phone over
  the LAN (`host` ICE candidates only; no STUN/TURN is configured).
- If the call fails to connect, the LAN is probably isolating clients or a phone
  has a VPN up. Retest on the hotspot.
- Stop the relay or lock either phone: both devices end and lock.

## 6. Optional LAN TURN (only if direct ICE fails)

A direct path normally works on a hotspot. If your topology blocks it, run Coturn
on the laptop and tell the relay to advertise it:

```bat
:: local_server\.env
SECRETPLAY_ICE_SERVERS=turn:192.168.137.1:3478?transport=udp
```

Coturn must be configured by you (realm, static credentials, `listening-ip` on the
LAN address). This project does not bundle or configure Coturn. Audio still
travels over the LAN; there is no Cloudflare involvement.

## 7. Stop

```bat
scripts\stop-local.bat
```

or Ctrl+C. Every session, token and invitation disappears. Restarting the relay
cannot restore anything: previous sessions are unrecoverable by design.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `dependencies are missing` | `npm ci` never ran | `install-local.bat` once with Internet |
| `EADDRINUSE` | Something on 8787 | Set `SECRETPLAY_PORT=8788` in `local_server\.env` |
| QR scans, then "cannot reach the relay" | Wrong address in the QR (network changed after start) | Restart `run-local.bat` on the new network |
| "expired" | Invitation older than 10 minutes or already used | Restart the relay to mint a fresh one |
| Chat connects but calls fail | AP/client isolation or a phone VPN | Use the hotspot; disable the VPN |
| Both phones lock constantly | Aggressive battery optimisation killing the socket | Disable battery optimisation for SecretPlay on both phones |
| No private IPv4 printed | Wi-Fi/hotspot off | Connect, then restart the relay |
