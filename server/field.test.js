'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { Relay, PROTOCOL } = require('./lib/relay');
const { cleanFieldSnapshot } = require('./lib/sanitize');

function peer() {
  return { messages: [], send(message) { this.messages.push(message); }, close() {} };
}

function connect(relay, name, map) {
  const wire = peer();
  const id = relay.accept(wire);
  relay.handle(id, { type: 'mmo.hello', proto: PROTOCOL, name, map, x: 1, y: 1 });
  wire.messages.length = 0;
  return { id, wire };
}

function ground(map = 'ROUTE_1') {
  return { domain: 'GROUND', map, epoch: 0, revision: 0, spawns: [{
    id: 'ground_1', species: 'PIDGEY', level: 3, x: 4, y: 5,
    facing: 'left', behavior: 'GRASS_WANDER', surface: 'GRASS', kind: 'grass',
  }] };
}

function domainSnapshots(map = 'PALLET') {
  return [
    ground(map),
    { domain: 'AMBIENT', map, epoch: 0, revision: 0,
      spawns: [{ id: 'ambient_1', species: 'RATTATA', x: 2, y: 3,
        facing: 'up', behavior: 'WANDER' }] },
    { domain: 'SKY', map, epoch: 0, revision: 0,
      spawns: [{ id: 'sky_1', species: 'PIDGEOT', level: 36, x: 200, y: 100,
        alt: 64, mode: 'roam', facing: 'right', vx: 2, vy: -1 }] },
    { domain: 'NPC', map, epoch: 0, revision: 0,
      spawns: [{ id: 'npc_1', x: 3, y: 4, moving: true,
        targetX: 4, targetY: 4, progress: 2 }] },
  ];
}

test('field sanitizer accepts each renderer-neutral domain', () => {
  for (const snapshot of domainSnapshots()) assert.ok(cleanFieldSnapshot(snapshot));
});

test('field sanitizer rejects sparse equivalents, oversized lists and bad rows', () => {
  const sparse = ground();
  sparse.spawns.length = 2;
  assert.equal(cleanFieldSnapshot(sparse), null);
  assert.equal(cleanFieldSnapshot({ ...ground(), domain: 'UNKNOWN' }), null);
  assert.equal(cleanFieldSnapshot({ ...ground(), spawns: Array(25).fill(ground().spawns[0]) }), null);
  assert.equal(cleanFieldSnapshot({ domain: 'AMBIENT', map: 'PALLET', revision: 0,
    spawns: [{ id: 'ambient_1', species: 'RATTATA', x: 2, y: 3,
      behavior: 'GRASS_WANDER' }] }), null);
});

test('hub seeds once, enforces CAS, and grants a claim atomically', () => {
  const relay = new Relay({ protocol: PROTOCOL, log: { debug() {}, info() {}, warn() {} } });
  const ann = connect(relay, 'ANN', 'ROUTE_1');
  const bob = connect(relay, 'BOB', 'ROUTE_1');

  relay.handle(ann.id, { type: 'mmo.field_seed', ...ground() });
  assert.equal(relay.wildFields.get('GROUND:ROUTE_1').revision, 1);
  assert.equal(ann.wire.messages.at(-1).type, 'mmo.field_snapshot');
  assert.equal(bob.wire.messages.at(-1).authority, ann.id);

  relay.handle(bob.id, { type: 'mmo.field_publish', ...ground(), revision: 1 });
  assert.equal(relay.wildFields.get('GROUND:ROUTE_1').revision, 1,
    'a non-authority cannot publish');
  relay.handle(ann.id, { type: 'mmo.field_publish', ...ground(), revision: 0 });
  assert.equal(relay.wildFields.get('GROUND:ROUTE_1').revision, 1,
    'a stale revision cannot publish');
  relay.handle(ann.id, { type: 'mmo.field_publish', ...ground(), epoch: 1, revision: 1 });
  assert.equal(relay.wildFields.get('GROUND:ROUTE_1').revision, 1,
    'a stale epoch cannot publish even with the current revision');
  relay.handle(ann.id, { type: 'mmo.field_publish', ...ground(), revision: 1 });
  assert.equal(relay.wildFields.get('GROUND:ROUTE_1').revision, 2,
    'the authority can compare-and-swap the current epoch and revision');

  ann.wire.messages.length = 0;
  relay.handle(ann.id, { type: 'mmo.field_claim', domain: 'GROUND',
    map: 'ROUTE_1', id: 'ground_1' });
  assert.deepEqual(ann.wire.messages.slice(-2).map(row => row.type),
    ['mmo.field_granted', 'mmo.field_snapshot']);
  assert.equal(relay.wildFields.get('GROUND:ROUTE_1').spawns.length, 0);
  relay.handle(bob.id, { type: 'mmo.field_claim', domain: 'GROUND',
    map: 'ROUTE_1', id: 'ground_1' });
  assert.equal(bob.wire.messages.at(-1).type, 'mmo.field_denied');
});

test('all domains occupy independent per-map caches', () => {
  const relay = new Relay({ protocol: PROTOCOL, log: { debug() {}, info() {}, warn() {} } });
  const ann = connect(relay, 'ANN', 'PALLET');
  for (const snapshot of domainSnapshots()) {
    relay.handle(ann.id, { type: 'mmo.field_seed', ...snapshot });
  }
  assert.deepEqual([...relay.wildFields.keys()].sort(),
    ['AMBIENT:PALLET', 'GROUND:PALLET', 'NPC:PALLET', 'SKY:PALLET']);
  const before = relay.wildFields.get('AMBIENT:PALLET');
  relay.handle(ann.id, { type: 'mmo.field_claim', domain: 'AMBIENT',
    map: 'PALLET', id: 'ambient_1' });
  assert.equal(relay.wildFields.get('AMBIENT:PALLET'), before,
    'display-only domains cannot be claimed');
});

test('authority is deterministic and warp vacancy advances refresh epochs', () => {
  const relay = new Relay({ protocol: PROTOCOL, log: { debug() {}, info() {}, warn() {} } });
  const ann = connect(relay, 'ANN', 'ROUTE_1');
  const bob = connect(relay, 'BOB', 'PALLET');
  relay.handle(ann.id, { type: 'mmo.field_seed', ...ground() });
  assert.equal(relay.fieldAuthorities.get('GROUND:ROUTE_1'), ann.id);

  relay.handle(ann.id, { type: 'mmo.move', map: 'PALLET', x: 2, y: 2,
    transition: 'warp' });
  assert.equal(relay.wildFields.has('GROUND:ROUTE_1'), false);
  assert.equal(relay.fieldEpochs.get('GROUND:ROUTE_1'), 1);
  ann.wire.messages.length = 0;
  bob.wire.messages.length = 0;
  relay.handle(bob.id, { type: 'mmo.field_request', domain: 'GROUND', map: 'ROUTE_1' });
  const needed = ann.wire.messages.find(row => row.type === 'mmo.field_needed');
  assert.equal(needed.epoch, 1);
  assert.equal(needed.reset, true);
});

test('SKY claims require a compatible flight state and altitude', () => {
  const relay = new Relay({ protocol: PROTOCOL, log: { debug() {}, info() {}, warn() {} } });
  const ann = connect(relay, 'ANN', 'ROUTE_1');
  const bob = connect(relay, 'BOB', 'ROUTE_1');
  const snapshot = domainSnapshots('ROUTE_1').find(row => row.domain === 'SKY');
  snapshot.spawns.push({ id: 'sky_low', species: 'SPEAROW', level: 5,
    x: 216, y: 100, alt: 10, mode: 'rise', facing: 'left', vx: -1, vy: 0 });
  relay.handle(ann.id, { type: 'mmo.field_seed', ...snapshot });

  relay.handle(ann.id, { type: 'mmo.field_claim', domain: 'SKY',
    map: 'ROUTE_1', id: 'sky_1' });
  assert.equal(ann.wire.messages.at(-1).type, 'mmo.field_denied',
    'a grounded player cannot contact a high flyer');

  relay.handle(bob.id, { type: 'mmo.move', map: 'ROUTE_1', x: 2, y: 1,
    airborne: true, altitude: 64, flightMount: 'PIDGEOT' });
  assert.equal(ann.wire.messages.at(-1).flightMount, 'PIDGEOT',
    'the relay preserves remote mount identity');
  relay.handle(bob.id, { type: 'mmo.field_claim', domain: 'SKY',
    map: 'ROUTE_1', id: 'sky_1' });
  assert.equal(bob.wire.messages.find(row => row.type === 'mmo.field_granted')?.id,
    'sky_1', 'a nearby airborne player can claim a flyer');

  relay.handle(bob.id, { type: 'mmo.field_claim', domain: 'SKY',
    map: 'ROUTE_1', id: 'sky_low' });
  assert.equal(bob.wire.messages.at(-1).type, 'mmo.field_denied',
    'an airborne player cannot claim outside the altitude band');

  relay.handle(ann.id, { type: 'mmo.field_claim', domain: 'SKY',
    map: 'ROUTE_1', id: 'sky_low' });
  assert.equal(ann.wire.messages.find(row => row.type === 'mmo.field_granted')?.id,
    'sky_low', 'a grounded player can contact a low flyer');
});
