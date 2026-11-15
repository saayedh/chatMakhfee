/**
 * Entry point for the laptop relay (`npm start`, or scripts/run-local.bat).
 *
 * Prints the laptop's LAN addresses, an admin token for local console actions,
 * and a QR code the phones scan. No outbound network access is required: there
 * is no telemetry, no DNS dependency and no Cloudflare involvement.
 */

import { writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import qrcode from 'qrcode-terminal';

import { loadConfig } from './config.ts';
import { describeAddresses, listLanAddresses, pickPrimaryAddress } from './net.ts';
import { createLocalServer } from './server.ts';

const PID_FILE = join(import.meta.dirname, '..', '.secretplay.pid');

function line(char = '-', width = 68): string {
  return char.repeat(width);
}

async function main(): Promise<void> {
  const config = loadConfig();
  const addresses = listLanAddresses();
  const primary = pickPrimaryAddress(addresses);

  const stamp = (): string => new Date().toISOString().slice(11, 19);

  const log = (event: string, fields?: Record<string, unknown>): void => {
    if (config.quiet) return;
    const detail = fields ? ` ${JSON.stringify(fields)}` : '';
    console.log(`[${stamp()}] ${event}${detail}`);
  };

  const server = await createLocalServer(config, {
    onLog: log,
    onInvite: (invite, qr) => {
      if (config.quiet) return;
      if (!invite || !qr) {
        console.log(`\n${line('=')}\n  PAIRING COMPLETE — both authorised devices are registered.\n${line('=')}\n`);
        return;
      }
      console.log(`\n${line('=')}`);
      console.log('  SCAN THIS QR WITH THE NEXT PHONE');
      console.log(`  Expires: ${new Date(invite.expiresAt).toLocaleTimeString()}`);
      console.log(`  Slot:    ${server.store.slotsFilled === 0 ? 'A' : 'B'} (only two exist, ever)`);
      console.log(line('='));
      qrcode.generate(qr, { small: true });
      console.log(line('='));
      console.log('  Or paste this URL into the app under "Local / Offline Mode":');
      console.log(`  ${server.httpOrigin()}  (pair ${server.store.pairId})`);
      console.log(`${line('=')}\n`);
    },
    onPairComplete: () => {
      log('pair.complete', { pairId: server.store.pairId });
    },
  });

  const { port } = await server.listen();

  if (!config.quiet) {
    console.log(`\n${line('=')}`);
    console.log('  SECRETPLAY LOCAL RELAY  (offline / LAN mode)');
    console.log(line('='));
    console.log(`  Protocol:  sp1 v1   Version: 1.0.0`);
    console.log(`  Pair id:   ${server.store.pairId}`);
    console.log(`  Port:      ${port}   Bind: ${config.host}`);
    console.log(`  Heartbeat: ${config.heartbeatMs}ms   Session timeout: ${config.sessionTimeoutMs}ms`);
    console.log(`\n  LAN addresses (give phones this network):\n${describeAddresses(addresses, port)}`);

    if (!primary) {
      console.log('\n  !! No private LAN IPv4 found. Connect Wi-Fi or start Windows Mobile Hotspot.');
      console.log('     Then run ipconfig and use that address, or restart this server.');
    } else if (primary.isPrivate === false) {
      console.log('\n  !! Only a PUBLIC address was found. Do not expose this relay to the internet.');
    }

    console.log(`\n  Admin token (console only, never share):\n  ${server.adminToken}`);
    console.log('\n  Health check: http://127.0.0.1:' + port + '/health');
    console.log(line('='));
    console.log('\n  WINDOWS MOBILE HOTSPOT (recommended, no router needed):');
    console.log('    1. Settings > Network & internet > Mobile hotspot > turn on');
    console.log('    2. Leave the band at 2.4 GHz for older phones');
    console.log('    3. Connect both phones to the hotspot SSID');
    console.log('    4. If phones cannot connect, allow Node.js through');
    console.log('       Windows Defender Firewall on PRIVATE networks only.');
    console.log('    5. Re-run run-local.bat after switching networks so the QR');
    console.log('       advertises the hotspot address (usually 192.168.137.1).');
    console.log(`\n  Press Ctrl+C to stop. Nothing is written to disk.\n`);
  }

  writeFileSync(PID_FILE, String(process.pid), 'utf8');

  const shutdown = (signal: string): void => {
    log('server.signal', { signal });
    void server.close().finally(() => {
      try {
        rmSync(PID_FILE, { force: true });
      } catch {
        // ignore
      }
      process.exit(0);
    });
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGHUP', () => shutdown('SIGHUP'));
}

main().catch((error: unknown) => {
  console.error('\nSecretPlay local relay failed to start.');
  console.error(error instanceof Error ? error.message : error);
  console.error('\nTroubleshooting:');
  console.error('  - Is port 8787 already in use? Set SECRETPLAY_PORT=8788 in local-server/.env');
  console.error('  - Did you run scripts\\install-local.bat once, with Internet available?');
  console.error('  - Node.js 22.18+ is required.');
  process.exit(1);
});
