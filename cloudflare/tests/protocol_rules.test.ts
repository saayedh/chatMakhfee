import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  SCHEMA_STATEMENTS,
  SchemaViolation,
  assertMetadataOnlySchema,
  planRegistration,
  type RegistrationSnapshot,
} from '../src/protocol_rules.ts';

function snapshot(overrides: Partial<RegistrationSnapshot> = {}): RegistrationSnapshot {
  return {
    devicesStored: 1,
    claimedDeviceId: 'd_abc',
    derivedDeviceId: 'd_abc',
    publicKeyBytes: 32,
    alreadyRegisteredRole: null,
    inviteUsable: true,
    targetSlotFree: true,
    ...overrides,
  };
}

test('the first device fills slot A, the second slot B', () => {
  const first = planRegistration(snapshot({ devicesStored: 0 }));
  assert.deepEqual(first, { ok: true, role: 'A', reissued: false });
  const second = planRegistration(snapshot({ devicesStored: 1 }));
  assert.deepEqual(second, { ok: true, role: 'B', reissued: false });
});

test('a third device is refused', () => {
  const plan = planRegistration(snapshot({ devicesStored: 2, targetSlotFree: false }));
  assert.equal(plan.ok, false);
  if (!plan.ok) assert.equal(plan.code, 'pair_full');
});

test('identity binding is checked before the invitation', () => {
  const plan = planRegistration(
    snapshot({ derivedDeviceId: 'd_other', claimedDeviceId: 'd_abc', inviteUsable: false }),
  );
  assert.equal(plan.ok, false);
  if (!plan.ok) assert.match(plan.detail, /deviceId/);
});

test('an unusable invitation blocks registration but is checked after identity', () => {
  const plan = planRegistration(snapshot({ inviteUsable: false }));
  assert.equal(plan.ok, false);
  if (!plan.ok) assert.equal(plan.code, 'unauthorized');
});

test('a re-registering device keeps its slot', () => {
  const plan = planRegistration(snapshot({ devicesStored: 2, alreadyRegisteredRole: 'B', targetSlotFree: false }));
  assert.deepEqual(plan, { ok: true, role: 'B', reissued: true });
});

test('a short public key is refused', () => {
  const plan = planRegistration(snapshot({ publicKeyBytes: 16 }));
  assert.equal(plan.ok, false);
  if (!plan.ok) assert.match(plan.detail, /32 bytes/);
});

test('the cloud schema is metadata-only', () => {
  assert.doesNotThrow(() => assertMetadataOnlySchema());
  const tables = SCHEMA_STATEMENTS.map((statement) => /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)/i.exec(statement)?.[1]);
  assert.deepEqual(tables, ['pairs', 'devices', 'invites', 'revocations']);
});

test('a message table is rejected by the guard', () => {
  assert.throws(
    () => assertMetadataOnlySchema([...SCHEMA_STATEMENTS, 'CREATE TABLE IF NOT EXISTS messages (id TEXT)']),
    (error: unknown) => error instanceof SchemaViolation,
  );
  assert.throws(
    () => assertMetadataOnlySchema(['CREATE TABLE chat_history (id TEXT)']),
    (error: unknown) => error instanceof SchemaViolation,
  );
});

test('non-CREATE data statements are rejected', () => {
  assert.throws(
    () => assertMetadataOnlySchema(['ALTER TABLE devices ADD COLUMN transcript TEXT']),
    (error: unknown) => error instanceof SchemaViolation,
  );
});
