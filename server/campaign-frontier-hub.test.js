'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { Relay } = require('./lib/relay');

const quiet = { debug() {}, info() {}, warn() {}, error() {} };
let joinSerial = 0;
function take(side, kind) {
  const index = side.peer.outbox.findIndex((message) => message.type === kind);
  return index < 0 ? null : side.peer.outbox.splice(index, 1)[0];
}
function join(relay, name) {
  const peer = { outbox: [], remoteAddress: '127.0.0.1',
    send(message) { this.outbox.push(message); }, close() {} };
  const id = relay.accept(peer);
  relay.handle(id, { type: 'mmo.hello', proto: 19, name,
    playerId: (++joinSerial).toString(16).padStart(32, '0'),
    map: 'PALLET', x: 1, y: 1, facing: 'down' });
  const side = { id, peer };
  const welcome = take(side, 'mmo.welcome');
  assert.ok(welcome);
  side.id = welcome.id;
  return side;
}

test('dedicated protocol-19 hub gates positions on acknowledged frontiers', () => {
  const relay = new Relay({ maxPlayers: 2, protocol: 19, log: quiet });
  const ann = join(relay, 'ANN');
  const bob = join(relay, 'BOB');
  const tag = 'a'.repeat(64);
  const D0 = 'b'.repeat(16); const R0 = 'c'.repeat(16);
  const inventory = (player, head, heads) => ({ schema: 1,
    world: 'frontier-world', compatibility: 'campaign-state.4.frontier',
    player, timelineHead: head, heads, tag });
  const frontier = (head, canonicalDigest, revision, heads) => ({ version: 1,
    world: 'frontier-world', compatibility: 'campaign-state.4.frontier',
    timelineHead: head, canonicalDigest, heads, revision, tag });
  const base = (position, baseDigest, revision) => ({ version: 1,
    world: 'frontier-world', compatibility: 'campaign-state.4.frontier',
    position, baseDigest, authorityRevision: revision, replicaRevision: revision });
  const acknowledge = (side, localFrontier, grantBase) => {
    relay.handle(side.id, { type: 'mmo.world_frontier_ack', admission: {
      frontier: localFrontier, authorityRevision: grantBase.authorityRevision,
      replicaRevision: grantBase.replicaRevision, grantBase,
    } });
    return take(side, 'mmo.world_frontier_ready');
  };

  const heads0 = { ann: 0, bob: 0 };
  const initial = frontier(0, D0, R0, heads0);
  relay.handle(ann.id, { type: 'mmo.world_advertise',
    inventory: inventory('ann', 0, heads0), frontier: initial });
  assert.equal(take(ann, 'mmo.world_ready'), null);
  assert.equal(take(ann, 'mmo.world_frontier').frontier.revision, R0);
  relay.handle(bob.id, { type: 'mmo.world_advertise',
    inventory: inventory('bob', 0, heads0), frontier: initial });
  assert.equal(take(bob, 'mmo.world_frontier').frontier.revision, R0);

  const base0 = base(1, D0, R0);
  relay.handle(ann.id, { type: 'mmo.world_sequence_request', request: 'early',
    actor: 'ann', kind: 'pokemon.unique.resolve', subject: 'articuno', base: base0 });
  assert.equal(take(ann, 'mmo.world_sequence_grant'), null);
  assert.ok(acknowledge(ann, initial, base0));
  assert.ok(acknowledge(bob, initial, base0));

  relay.handle(ann.id, { type: 'mmo.world_sequence_request', request: 'one',
    actor: 'ann', kind: 'pokemon.unique.resolve', subject: 'articuno', base: base0 });
  const grant = take(ann, 'mmo.world_sequence_grant');
  assert.equal(grant.position, 1);
  assert.equal(grant.base.baseDigest, D0);
  const event = { schema: 1, id: 'ann:1', world: 'frontier-world', actor: 'ann',
    seq: 1, position: 1, transaction: 'frontier-transaction-one', owner: 'world',
    kind: 'pokemon.unique.resolve', subject: 'articuno',
    payload: { outcome: 'captured' } };
  relay.handle(ann.id, { type: 'mmo.world_events', envelope: { schema: 1,
    world: 'frontier-world', compatibility: 'campaign-state.4.frontier',
    events: [event], tag } });
  relay.handle(ann.id, { type: 'mmo.world_sequence_commit', request: grant.request,
    grant: grant.grant, world: grant.world, position: grant.position });

  const D1 = 'd'.repeat(16); const R1 = 'e'.repeat(16);
  const heads1 = { ann: 1, bob: 0 };
  const advanced = frontier(1, D1, R1, heads1);
  relay.handle(ann.id, { type: 'mmo.world_advertise',
    inventory: inventory('ann', 1, heads1), frontier: advanced });
  assert.equal(take(bob, 'mmo.world_sequence_grant'), null);
  assert.equal(take(bob, 'mmo.world_frontier').frontier.revision, R1);
  assert.equal(take(ann, 'mmo.world_frontier').frontier.revision, R1);
  assert.ok(acknowledge(ann, advanced, base(2, D1, R1)));
  relay.handle(bob.id, { type: 'mmo.world_advertise',
    inventory: inventory('bob', 1, heads1), frontier: advanced });
  take(bob, 'mmo.world_frontier');
  assert.ok(acknowledge(bob, advanced, base(2, D1, R1)));
  relay.handle(bob.id, { type: 'mmo.world_sequence_request', request: 'two',
    actor: 'bob', kind: 'pokemon.unique.resolve', subject: 'zapdos',
    base: base(2, D1, R1) });
  const grant2 = take(bob, 'mmo.world_sequence_grant');
  assert.equal(grant2.position, 2);

  const event2 = { schema: 1, id: 'bob:1', world: 'frontier-world', actor: 'bob',
    seq: 1, position: 2, transaction: 'frontier-transaction-two', owner: 'world',
    kind: 'pokemon.unique.resolve', subject: 'zapdos', payload: { outcome: 'escaped' } };
  relay.handle(bob.id, { type: 'mmo.world_events', envelope: { schema: 1,
    world: 'frontier-world', compatibility: 'campaign-state.4.frontier',
    events: [event2], tag } });
  relay.handle(ann.id, { type: 'mmo.world_sequence_request', request: 'held-three',
    actor: 'ann', kind: 'pokemon.unique.resolve', subject: 'mewtwo',
    base: base(2, D1, R1) });
  relay.handle(bob.id, { type: 'mmo.world_sequence_cancel',
    request: grant2.request, grant: grant2.grant });
  assert.equal(take(ann, 'mmo.world_sequence_grant'), null);
  assert.equal(relay.drop(bob.id), true);

  const D2 = 'f'.repeat(16); const R2 = '1'.repeat(16);
  const heads2 = { ann: 1, bob: 1 };
  const recovered = frontier(2, D2, R2, heads2);
  relay.handle(ann.id, { type: 'mmo.world_advertise',
    inventory: inventory('ann', 2, heads2), frontier: recovered });
  assert.equal(take(ann, 'mmo.world_frontier').frontier.revision, R2);
  assert.equal(acknowledge(ann, recovered, base(3, D2, '2'.repeat(16))), null);
  assert.ok(acknowledge(ann, recovered, base(3, D2, R2)));
  relay.handle(ann.id, { type: 'mmo.world_sequence_request', request: 'three',
    actor: 'ann', kind: 'pokemon.unique.resolve', subject: 'mewtwo',
    base: base(3, D2, R2) });
  assert.equal(take(ann, 'mmo.world_sequence_grant').position, 3);

  const R3 = '3'.repeat(16); const heads3 = { ann: 2, bob: 1 };
  const actorAdvanced = frontier(2, D2, R3, heads3);
  relay.handle(ann.id, { type: 'mmo.world_advertise',
    inventory: inventory('ann', 2, heads3), frontier: actorAdvanced });
  assert.equal(take(ann, 'mmo.world_frontier').frontier.revision, R3);
  assert.ok(acknowledge(ann, actorAdvanced, base(3, D2, R3)));
  relay.handle(ann.id, { type: 'mmo.world_sequence_request',
    request: 'three-after-actor', actor: 'ann', kind: 'pokemon.unique.resolve',
    subject: 'mewtwo', base: base(3, D2, R3) });
  assert.equal(take(ann, 'mmo.world_sequence_grant').position, 3);

  const copy = join(relay, 'COPY');
  relay.handle(copy.id, { type: 'mmo.world_advertise',
    inventory: inventory('ann', 2, heads3), frontier: actorAdvanced });
  assert.equal(take(copy, 'mmo.world_unavailable').reason, 'duplicate_player');

  const restarted = new Relay({ maxPlayers: 2, protocol: 19, log: quiet });
  const behind = join(restarted, 'BEHIND');
  const ahead = join(restarted, 'AHEAD');
  restarted.handle(behind.id, { type: 'mmo.world_advertise',
    inventory: inventory('ann', 0, heads0), frontier: initial });
  take(behind, 'mmo.world_frontier');
  restarted.handle(ahead.id, { type: 'mmo.world_advertise',
    inventory: inventory('bob', 1, heads1), frontier: advanced });
  assert.equal(take(ahead, 'mmo.world_frontier').frontier.revision, R0);
  const gapEvent = { schema: 1, id: 'bob:2', world: 'frontier-world', actor: 'bob',
    seq: 2, position: 2, transaction: 'frontier-transaction-gap', owner: 'world',
    kind: 'pokemon.unique.resolve', subject: 'moltres', payload: { outcome: 'escaped' } };
  const gapHeads = { ann: 0, bob: 2 };
  const gapFrontier = frontier(2, D2, R2, gapHeads);
  restarted.handle(ahead.id, { type: 'mmo.world_events', to: behind.id,
    envelope: { schema: 1, world: 'frontier-world',
      compatibility: 'campaign-state.4.frontier', events: [gapEvent], tag } });
  take(behind, 'mmo.world_events');
  restarted.handle(behind.id, { type: 'mmo.world_advertise',
    inventory: inventory('ann', 2, gapHeads), frontier: gapFrontier });
  assert.equal(take(behind, 'mmo.world_frontier').frontier.revision, R0);
  restarted.handle(ahead.id, { type: 'mmo.world_events', to: behind.id,
    envelope: { schema: 1, world: 'frontier-world',
      compatibility: 'campaign-state.4.frontier', events: [event], tag } });
  assert.ok(take(behind, 'mmo.world_events'));
  restarted.handle(behind.id, { type: 'mmo.world_advertise',
    inventory: inventory('ann', 1, heads1), frontier: advanced });
  assert.equal(take(behind, 'mmo.world_frontier').frontier.revision, R1);
  restarted.handle(behind.id, { type: 'mmo.world_frontier_ack', admission: {
    frontier: advanced, authorityRevision: R1, replicaRevision: R1,
    grantBase: base(2, D1, R1),
  } });
  assert.ok(take(behind, 'mmo.world_frontier_ready'));
  restarted.handle(behind.id, { type: 'mmo.world_sequence_request',
    request: 'restart-two', actor: 'ann', kind: 'pokemon.unique.resolve',
    subject: 'moltres', base: base(2, D1, R1) });
  assert.equal(take(behind, 'mmo.world_sequence_grant').position, 2);
});
