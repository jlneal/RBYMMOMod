'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { Relay } = require('./lib/relay');
const campaignAuthority = require('./lib/campaign-authority');

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
  relay.handle(id, { type: 'mmo.hello', proto: relay.protocol, name,
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

test('dedicated protocol-24 hub relays bounded prefixes and acknowledged frames', () => {
  const relay = new Relay({ maxPlayers: 2, protocol: 24, log: quiet });
  const ann = join(relay, 'PREFIXANN');
  const bob = join(relay, 'PREFIXBOB');
  const world = 'prefix-world';
  const compatibility = 'campaign-state.4.prefix';
  const heads = { ann: 0, bob: 0 };
  const frontier = { version: 1, world, compatibility, timelineHead: 0,
    canonicalDigest: '1'.repeat(16), heads, revision: '2'.repeat(16),
    tag: '3'.repeat(64) };
  const inventory = (player) => ({ schema: 1, world, compatibility, player,
    timelineHead: 0, heads, tag: '4'.repeat(64) });
  relay.handle(ann.id, { type: 'mmo.world_advertise',
    inventory: inventory('ann'), frontier });
  relay.handle(bob.id, { type: 'mmo.world_advertise',
    inventory: inventory('bob'), frontier });

  const packageValue = { schema: 1, world, compatibility,
    base: { schema: 1, world, compatibility, timelineHead: 0, events: 0,
      canonicalDigest: '1'.repeat(16), stateDigest: '5'.repeat(16),
      checkpointRevision: '6'.repeat(16), closureDigest: '7'.repeat(16),
      heads: {}, state: { world: {}, player: {} }, closed: true,
      tag: '8'.repeat(64) }, batches: [], frontier };
  relay.handle(ann.id, { type: 'mmo.world_prefix', to: bob.id,
    package: packageValue });
  const response = take(bob, 'mmo.world_prefix');
  assert.equal(response.from, ann.id);
  assert.equal(response.package.base.closed, true);

  const malformed = structuredClone(packageValue);
  malformed.base.heads = { ann: 1 };
  relay.handle(ann.id, { type: 'mmo.world_prefix', to: bob.id,
    package: malformed });
  assert.equal(take(bob, 'mmo.world_prefix'), null,
    'the relay refuses a malformed compact boundary');

  const frame = { schema: 1, world, compatibility, transfer: '9'.repeat(32),
    index: 2, total: 2, kind: 'state',
    payload: { path: ['world'], empty: true } };
  relay.handle(ann.id, { type: 'mmo.world_prefix_frame', to: bob.id, frame });
  const relayedFrame = take(bob, 'mmo.world_prefix_frame');
  assert.equal(relayedFrame.from, ann.id);
  assert.equal(relayedFrame.frame.transfer, frame.transfer);
  relay.handle(bob.id, { type: 'mmo.world_prefix_frame_ack', to: ann.id,
    transfer: frame.transfer, index: frame.index });
  const acknowledgement = take(ann, 'mmo.world_prefix_frame_ack');
  assert.equal(acknowledgement.from, bob.id);
  assert.equal(acknowledgement.index, frame.index);
});

test('protocol-29 campaign archive survives vacancy and hydrates a stale replica', () => {
  let persisted = null;
  const relay = new Relay({ maxPlayers: 2, protocol: 29, log: quiet,
    onCampaignChange(value) { persisted = structuredClone(value); } });
  const ann = join(relay, 'DURABLEANN');
  const tag = 'a'.repeat(64);
  const world = 'durable-world'; const compatibility = 'campaign-state.4.durable';
  const event = { schema: 1, id: 'ann:1', world, actor: 'ann', seq: 1,
    position: 1, transaction: 'durable-transaction-one', owner: 'world',
    kind: 'pokemon.unique.resolve', subject: 'articuno', payload: { outcome: 'captured' } };
  const batch = { schema: 1, world, compatibility, events: [event], tag };
  const heads1 = { ann: 1 };
  const frontier1 = { version: 1, world, compatibility, timelineHead: 1,
    canonicalDigest: 'b'.repeat(16), heads: heads1,
    revision: 'c'.repeat(16), tag };
  const inventory1 = { schema: 1, world, compatibility, player: 'ann',
    timelineHead: 1, heads: heads1, tag };
  relay.handle(ann.id, { type: 'mmo.world_archive_begin', inventory: inventory1,
    frontier: frontier1, batches: 1 });
  relay.handle(ann.id, { type: 'mmo.world_archive_batch', envelope: batch });
  relay.handle(ann.id, { type: 'mmo.world_archive_end', world, compatibility,
    revision: frontier1.revision });
  assert.equal(take(ann, 'mmo.world_archive_ready').revision, frontier1.revision);
  assert.equal(persisted.worlds[0].frontier.revision, frontier1.revision);
  relay.drop(ann.id);
  assert.equal(relay.worldTimelines.size, 1, 'vacancy does not erase canon');

  const restarted = new Relay({ maxPlayers: 2, protocol: 29, log: quiet,
    campaignArchive: campaignAuthority.exportArchive(relay) });
  const stale = join(restarted, 'DURABLESTALE');
  const heads0 = { ann: 0 };
  const frontier0 = { ...frontier1, timelineHead: 0, heads: heads0,
    canonicalDigest: 'd'.repeat(16), revision: 'e'.repeat(16) };
  const inventory0 = { ...inventory1, player: 'bob', timelineHead: 0, heads: heads0 };
  restarted.handle(stale.id, { type: 'mmo.world_archive_begin',
    inventory: inventory0, frontier: frontier0, batches: 0 });
  restarted.handle(stale.id, { type: 'mmo.world_archive_end', world, compatibility,
    revision: frontier0.revision });
  assert.ok(take(stale, 'mmo.world_archive_ready'));
  restarted.handle(stale.id, { type: 'mmo.world_advertise',
    inventory: inventory0, frontier: frontier0 });
  assert.equal(take(stale, 'mmo.world_events').from, 'campaign-authority');
  assert.equal(take(stale, 'mmo.world_frontier').frontier.revision,
    frontier1.revision);

  const conflict = { ...frontier1, canonicalDigest: 'f'.repeat(16),
    revision: '1'.repeat(16) };
  restarted.handle(stale.id, { type: 'mmo.world_advertise',
    inventory: inventory1, frontier: conflict });
  assert.equal(take(stale, 'mmo.world_unavailable').reason, 'archive_conflict');
});

test('protocol-29 restart recovers a published occupant before frontier acknowledgement', () => {
  const relay = new Relay({ maxPlayers: 1, protocol: 29, log: quiet });
  const ann = join(relay, 'CRASHANN');
  const world = 'crash-window-world'; const compatibility = 'campaign-state.4.durable';
  const tag = '2'.repeat(64); const D0 = '3'.repeat(16); const R0 = '4'.repeat(16);
  const heads0 = { ann: 0 };
  const frontier0 = { version: 1, world, compatibility, timelineHead: 0,
    canonicalDigest: D0, heads: heads0, revision: R0, tag };
  const inventory0 = { schema: 1, world, compatibility, player: 'ann',
    timelineHead: 0, heads: heads0, tag };
  relay.handle(ann.id, { type: 'mmo.world_archive_begin', inventory: inventory0,
    frontier: frontier0, batches: 0 });
  take(ann, 'mmo.world_archive_needed');
  relay.handle(ann.id, { type: 'mmo.world_archive_end', world, compatibility,
    revision: R0 });
  take(ann, 'mmo.world_archive_ready');
  relay.handle(ann.id, { type: 'mmo.world_advertise', inventory: inventory0,
    frontier: frontier0 });
  take(ann, 'mmo.world_frontier');
  const grantBase = { version: 1, world, compatibility, position: 1,
    baseDigest: D0, authorityRevision: R0, replicaRevision: R0 };
  relay.handle(ann.id, { type: 'mmo.world_frontier_ack', admission: {
    frontier: frontier0, authorityRevision: R0, replicaRevision: R0, grantBase } });
  take(ann, 'mmo.world_frontier_ready');
  relay.handle(ann.id, { type: 'mmo.world_sequence_request', request: 'crash-one',
    actor: 'ann', kind: 'pokemon.unique.resolve', subject: 'articuno', base: grantBase });
  const grant = take(ann, 'mmo.world_sequence_grant');
  const event = { schema: 1, id: 'ann:1', world, actor: 'ann', seq: 1,
    position: 1, transaction: 'crash-window-transaction', owner: 'world',
    kind: 'pokemon.unique.resolve', subject: 'articuno', payload: { outcome: 'captured' } };
  relay.handle(ann.id, { type: 'mmo.world_events', envelope: {
    schema: 1, world, compatibility, events: [event], tag } });
  const crashImage = campaignAuthority.exportArchive(relay);
  assert.equal(crashImage.worlds[0].frontier.revision, R0,
    'disk image may precede the author frontier but retains its signed occupant');

  const restarted = new Relay({ maxPlayers: 1, protocol: 29, log: quiet,
    campaignArchive: crashImage });
  const returner = join(restarted, 'CRASHRETURN');
  const frontier1 = { ...frontier0, timelineHead: 1, heads: { ann: 1 },
    canonicalDigest: '5'.repeat(16), revision: '6'.repeat(16) };
  const inventory1 = { ...inventory0, timelineHead: 1, heads: { ann: 1 } };
  restarted.handle(returner.id, { type: 'mmo.world_archive_begin',
    inventory: inventory1, frontier: frontier1, batches: 1 });
  assert.ok(take(returner, 'mmo.world_archive_ready'));
  restarted.handle(returner.id, { type: 'mmo.world_advertise',
    inventory: inventory1, frontier: frontier1 });
  assert.equal(restarted.worldTimelines.get(`${world}|${compatibility}`)
    .frontier.revision, frontier1.revision);
  assert.equal(take(returner, 'mmo.world_frontier').frontier.revision,
    frontier1.revision, 'recovered occupant is never reopened as position one');
});

test('protocol-29 refuses authority when canonical storage cannot commit', () => {
  const relay = new Relay({ maxPlayers: 1, protocol: 29, log: quiet,
    onCampaignChange() { return false; } });
  const ann = join(relay, 'FULLDISK');
  const world = 'failed-store-world'; const compatibility = 'campaign-state.4.durable';
  const frontier = { version: 1, world, compatibility, timelineHead: 0,
    canonicalDigest: '7'.repeat(16), heads: {}, revision: '8'.repeat(16),
    tag: '9'.repeat(64) };
  const inventory = { schema: 1, world, compatibility, player: 'ann',
    timelineHead: 0, heads: {}, tag: 'a'.repeat(64) };
  relay.handle(ann.id, { type: 'mmo.world_archive_begin', inventory, frontier,
    batches: 0 });
  take(ann, 'mmo.world_archive_needed');
  relay.handle(ann.id, { type: 'mmo.world_archive_end', world, compatibility,
    revision: frontier.revision });
  assert.equal(take(ann, 'mmo.world_archive_ready'), null);
  assert.equal(take(ann, 'mmo.world_unavailable').reason, 'archive_storage_failed');
  assert.equal(relay.worldTimelines.size, 0);
});
