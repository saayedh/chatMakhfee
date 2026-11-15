/**
 * LAN interface discovery, used for the startup banner, the QR payload and the
 * Windows Mobile Hotspot instructions.
 *
 * Only IPv4 is reported: the pairing QR points Android phones at
 * `ws://<lan-ip>:<port>`, and private/link-local addresses are preferred over
 * anything routable.
 */

import { networkInterfaces } from 'node:os';

export interface LanAddress {
  interfaceName: string;
  address: string;
  /** RFC1918 / link-local. A public address is a red flag for this mode. */
  isPrivate: boolean;
  /** Typical Windows Mobile Hotspot / ICS adapter address. */
  looksLikeHotspot: boolean;
}

const PRIVATE_PATTERNS: Array<{ test: (octets: number[]) => boolean; hotspot: boolean }> = [
  { test: (o) => o[0] === 192 && o[1] === 168, hotspot: false },
  { test: (o) => o[0] === 10, hotspot: false },
  { test: (o) => o[0] === 172 && (o[1] ?? 0) >= 16 && (o[1] ?? 0) <= 31, hotspot: false },
  { test: (o) => o[0] === 169 && o[1] === 254, hotspot: false },
];

/** Windows Mobile Hotspot is usually 192.168.137.1; ICS gateways vary. */
function hotspotHint(address: string, interfaceName: string): boolean {
  if (address.startsWith('192.168.137.')) return true;
  const name = interfaceName.toLowerCase();
  return name.includes('local area connection') || name.includes('wi-fi direct') || name.includes('hotspot');
}

export function listLanAddresses(): LanAddress[] {
  const out: LanAddress[] = [];
  for (const [interfaceName, entries] of Object.entries(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family !== 'IPv4' || entry.internal) continue;
      const octets = entry.address.split('.').map((part) => Number(part));
      if (octets.length !== 4 || octets.some((value) => !Number.isInteger(value))) continue;
      out.push({
        interfaceName,
        address: entry.address,
        isPrivate: PRIVATE_PATTERNS.some((pattern) => pattern.test(octets)),
        looksLikeHotspot: hotspotHint(entry.address, interfaceName),
      });
    }
  }
  out.sort((a, b) => {
    if (a.looksLikeHotspot !== b.looksLikeHotspot) return a.looksLikeHotspot ? -1 : 1;
    if (a.isPrivate !== b.isPrivate) return a.isPrivate ? -1 : 1;
    return a.interfaceName.localeCompare(b.interfaceName);
  });
  return out;
}

export function pickPrimaryAddress(addresses: LanAddress[] = listLanAddresses()): LanAddress | null {
  return addresses.find((entry) => entry.isPrivate && entry.looksLikeHotspot) ?? addresses.find((e) => e.isPrivate) ?? null;
}

export function describeAddresses(addresses: LanAddress[], port: number): string {
  if (addresses.length === 0) {
    return 'No LAN IPv4 address found. Check Wi-Fi / hotspot, then run ipconfig.';
  }
  return addresses
    .map((entry) => {
      const tag = entry.looksLikeHotspot ? 'hotspot' : entry.isPrivate ? 'private' : 'PUBLIC - do not use';
      return `  ${entry.interfaceName.padEnd(28)} http://${entry.address}:${port}   [${tag}]`;
    })
    .join('\n');
}
