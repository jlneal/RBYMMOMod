#!/usr/bin/env node
'use strict';

/*
 * Mediated battles on the Node hub (PROTOCOL 10).
 *
 * Pins the path the plan names for Wave 2: two dialed clients open a battle
 * session, upload a ruleset and parties, exchange choices, and receive a
 * single mmo.battle_outcome from the intermediator -- with no mmo.relay
 * lockstep and no dual mmo.result vote.
 *
 * Socket-free: Relay talks to peer handles, same idiom as sprite.test.js /
 * rank.test.js.
 *
 * Run: node server/hub_battle.test.js
 */

const { Relay, PROTOCOL, DEFAULT_SPRITE } = require('./lib/relay.js');
const { createLog } = require('./lib/log.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

const quiet = createLog({ level: 'error' });

function makeClock(start = 1_000_000) {
  let t = start;
  return { now: () => t, advance(ms) { t += ms; } };
}

function makeRelay(clock, opts) {
  const relay = new Relay(Object.assign(
    { maxPlayers: 8, log: quiet, now: clock.now }, opts || {}));
  // The seed is the intermediator's, so a suite that wants a reproducible fight
  // asks the relay rather than sending one in a ruleset -- which is exactly the
  // thing tryStartSim now refuses to read.
  relay.forceBattleSeed = 1;
  return relay;
}

function testPlayerId(seed) {
  const crypto = require('node:crypto');
  return crypto.createHash('sha256').update(String(seed)).digest('hex').slice(0, 32);
}

function dial(relay, name, opts) {
  const o = opts || {};
  const peer = { outbox: [], remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => {};
  const id = relay.accept(peer);
  const playerId = o.playerId || testPlayerId(name);
  relay.handle(id, {
    type: 'mmo.hello',
    proto: PROTOCOL,
    name,
    sprite: o.sprite || DEFAULT_SPRITE,
    map: o.map === undefined ? 'PALLET' : o.map,
    x: o.x === undefined ? 1 : o.x,
    y: o.y === undefined ? 1 : o.y,
    facing: 'down',
    playerId,
  });
  // Wire id is the persistent playerId; ephemeral accept id still routes handle().
  return { id: playerId, peer, name, ephemeralId: id };
}

function take(player, type) {
  const index = player.peer.outbox.findIndex((m) => m.type === type);
  if (index < 0) return null;
  return player.peer.outbox.splice(index, 1)[0];
}

function takeAll(player, type) {
  const out = [];
  for (;;) {
    const msg = take(player, type);
    if (!msg) return out;
    out.push(msg);
  }
}

function mon(power, hp) {
  return {
    species: 'MONA',
    level: 50,
    hp: hp === undefined ? 100 : hp,
    maxHp: Math.max(100, hp === undefined ? 100 : hp),
    stats: { atk: 120, def: 40, spd: 80, spc: 80 },
    moves: [{
      id: 'm1', pp: 15, power, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  };
}

function openBattle(relay, a, b) {
  a.peer.outbox = [];
  b.peer.outbox = [];
  relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
  ok(take(b, 'mmo.request') !== null, 'guest sees the battle ask');
  relay.handle(b.id, {
    type: 'mmo.respond', to: a.id, kind: 'battle', accept: true,
  });
  const hostSess = take(a, 'mmo.session');
  const guestSess = take(b, 'mmo.session');
  ok(hostSess && hostSess.role === 'host' && hostSess.id,
    'asker is named host of a battle session');
  ok(guestSess && guestSess.role === 'guest' && guestSess.id === hostSess.id,
    'guest shares the same session id');
  ok(relay.battles.has(hostSess.id),
    'a mediated battle record exists for the session');
  ok(/^s\d+$/.test(hostSess.id),
    'a session id carries the letter that keeps it out of the co-op id space');
  return hostSess;
}

function uploadAndReady(relay, a, b, session, opts) {
  const o = opts || {};
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset',
    chart: o.chart || [[100]],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: o.aMons || [mon(90)],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: o.bMons || [mon(20)],
  });
  const readyA = take(a, 'mmo.battle_ready');
  const readyB = take(b, 'mmo.battle_ready');
  ok(readyA && readyA.mode === '1v1' && readyB && readyB.battle === session.id,
    'both sides hear battle_ready once parties land');
  return readyA;
}

function testMediatedOneVOneKo() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'HOST');
  const b = dial(relay, 'GUEST');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  uploadAndReady(relay, a, b, session);
  relay.clients.get(a.id).worldState = {
    world: 'shared-world', compatibility: 'same', player: 'campaign-ann',
  };
  relay.clients.get(b.id).worldState = {
    world: 'shared-world', compatibility: 'same', player: 'campaign-bob',
  };
  relay.battles.get(session.id).campaignOccurrence = 'rby:gym:campaign-ann.1';
  relay.battles.get(session.id).campaignDefinition = '0123456789abcdef';

  let outcome = null;
  for (let turn = 0; turn < 30; turn++) {
    takeAll(a, 'mmo.battle_event');
    takeAll(b, 'mmo.battle_event');
    if (!relay.battles.has(session.id)) break;
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: session.id,
      action: 'fight', move: 0, target: 2,
    });
    relay.handle(b.id, {
      type: 'mmo.battle_choice', battle: session.id,
      action: 'fight', move: 0, target: 0,
    });
    outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
    if (outcome) break;
  }
  ok(outcome && outcome.reason === 'ko',
    'intermediator ends the fight with a ko outcome');
  ok(Array.isArray(outcome.winners) && outcome.winners.length === 1,
    'outcome names a winner');
  ok(Array.isArray(outcome.participants) && outcome.participants.length === 2,
    'outcome snapshots both connected finishers');
  ok(Array.isArray(outcome.acted) && outcome.acted.length === 2,
    'outcome snapshots both resolved-turn actors');
  ok(outcome.campaignWorld === 'shared-world'
      && outcome.campaignHost === 'campaign-ann',
  'outcome binds admitted campaign world and host identity');
  ok(outcome.campaignParticipants.join(',') === 'campaign-ann,campaign-bob'
      && outcome.campaignActed.join(',') === 'campaign-ann,campaign-bob',
  'outcome translates final presence and action through one identity map');
  ok(outcome.campaignGeneration === 1 && outcome.campaignRevision >= 2,
    'outcome binds host generation and monotonic evidence revision');
  ok(outcome.campaignHosts.join(',') === 'campaign-ann',
    'outcome carries the authenticated host history, not only its generation');
  ok(outcome.campaignOccurrence === 'rby:gym:campaign-ann.1'
      && outcome.campaignDefinition === '0123456789abcdef',
  'outcome binds the content-minted occurrence and local definition');
  ok(!relay.battles.has(session.id),
    'the mediated record is cleared after settle');
}

function testRelayHardCutDuringBattle() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'CUTA');
  const b = dial(relay, 'CUTB');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  uploadAndReady(relay, a, b, session);
  a.peer.outbox = [];
  b.peer.outbox = [];
  relay.handle(a.id, {
    type: 'mmo.relay', to: b.id, payload: { type: 'action', move: 1 },
  });
  ok(take(b, 'mmo.relay') === null,
    'opaque mmo.relay is dropped once the battle is mediated');
}

function testDisconnectForfeitAfterGrace() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'STAYA');
  const b = dial(relay, 'DROPB');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  uploadAndReady(relay, a, b, session, {
    aMons: [mon(40)],
    bMons: [mon(40)],
  });
  a.peer.outbox = [];
  b.peer.outbox = [];

  // Guest drops mid-fight; grace starts.
  ok(relay.leaveBattle(relay.get(b.id)) === true,
    'leaveBattle starts reconnect grace on a live sim');

  // Still within grace: no outcome yet.
  clock.advance(30_000);
  relay.tickBattles();
  ok(take(a, 'mmo.battle_outcome') === null,
    'no forfeit before the grace expires');

  // Past grace.
  clock.advance(40_000);
  relay.tickBattles();
  const outcome = take(a, 'mmo.battle_outcome');
  ok(outcome && outcome.outcome === 'forfeit',
    'past grace the missing side forfeits via intermediator outcome');
  ok(outcome.reason === 'disconnect', 'and the outcome says why');
  ok(outcome.winners.length === 1 && outcome.winners[0] === a.id,
    'naming the player who was still there as the winner');
  ok(outcome.losers.length === 1 && outcome.losers[0] === b.id,
    'and the one who left as the loser');
}

/*
 * A fight nobody won, and the shape of saying so.
 *
 * cleanBattleOutcome refuses an empty id list, so a draw carrying two of them is
 * a message no client reads -- a battle screen with no way out. The absence is
 * the statement, which is what the Lua hub has always done and what this one used
 * to get wrong by sending `winners: []`.
 */
function testDrawCarriesNoLists() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'DRAWA');
  const b = dial(relay, 'DRAWB');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  uploadAndReady(relay, a, b, session, { aMons: [mon(40)], bMons: [mon(40)] });
  a.peer.outbox = [];
  b.peer.outbox = [];

  // Both sides run, which the turn machine reads as a mutual concession.
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: session.id, action: 'run',
  });
  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: session.id, action: 'run',
  });
  const outcome = take(a, 'mmo.battle_outcome');
  ok(outcome && outcome.outcome === 'draw', 'both running is a draw');
  ok(outcome.winners === undefined && outcome.losers === undefined,
    'carrying neither list rather than two empty ones');
  ok(outcome.reason === 'run', 'and still saying why it ended');
}

/*
 * Two players against a trainer, refereed.
 *
 * The two things coop_npc was waiting on: two seats for the trainer rather than
 * one, and something to answer for them. Nothing below advances the clock, so a
 * turn that needed the choice deadline to close would never close at all.
 */
function testCoopNpcMediated() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'NPCA');
  const b = dial(relay, 'NPCB');
  relay.openCoopBattle('c1', [a.id, b.id],
    { mode: 'coop_npc', hostId: a.id });
  const record = relay.battles.get('c1');
  ok(record && record.npcIds.length === 2,
    'a coop_npc seats the trainer twice, because the screen draws two of it');
  ok(record.npcIds[0] === 'nc1a' && record.npcIds[1] === 'nc1b',
    'under ids named off the battle and legal on the wire');
  a.peer.outbox = [];
  b.peer.outbox = [];

  relay.handle(a.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'c1', side: 'a', mons: [mon(200)],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'c1', side: 'a', mons: [mon(200)],
  });
  ok(record.sim === null,
    'two players are not a field: the trainer owes a team too');

  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'c1',
    side: 'b',
    mons: [mon(10, 1), mon(10, 1)],
  });
  ok(record.sim !== null,
    "the host's second party is what completes the set");
  ok(record.parties.get('nc1a').mons.length === 1
    && record.parties.get('nc1b').mons.length === 1,
    "and the trainer's team is dealt one to each seat");

  const ready = take(a, 'mmo.battle_ready');
  ok(ready && ready.sides.b.length === 2,
    'both trainer seats are advertised on side b');
  ok(ready.sides.b[0] === 'nc1a',
    'under their own ids rather than behind the host, so the screen can map '
    + 'each of them onto a box it is already drawing');

  let outcome = null;
  for (let turn = 0; turn < 30; turn += 1) {
    takeAll(a, 'mmo.battle_event');
    takeAll(b, 'mmo.battle_event');
    if (!relay.battles.has('c1')) break;
    for (const player of [a, b]) {
      relay.handle(player.id, {
        type: 'mmo.battle_choice', battle: 'c1', action: 'fight', move: 0,
      });
    }
    outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
    if (outcome) break;
  }
  ok(outcome && outcome.outcome === 'win',
    'the fight runs to an end with nobody waiting on a clock');
  ok(outcome.winners.includes(a.id) && outcome.winners.includes(b.id),
    'with the two players named as the winners');
  ok(outcome.losers.includes('nc1a'),
    "and the trainer's seats as the side that lost");
  ok(clock.now() === 1_000_000,
    'and no time passed at all -- the trainer answered in the same breath');
}

function testTradeRelayStillWorks() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'TRADA');
  const b = dial(relay, 'TRADB');
  a.peer.outbox = [];
  b.peer.outbox = [];
  relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'trade' });
  relay.handle(b.id, {
    type: 'mmo.respond', to: a.id, kind: 'trade', accept: true,
  });
  const session = take(a, 'mmo.session');
  ok(session && session.kind === 'trade', 'trade session opens');
  ok(!relay.battles.has(session.id),
    'a trade does not open a mediated battle record');
  a.peer.outbox = [];
  b.peer.outbox = [];
  relay.handle(a.id, {
    type: 'mmo.relay', to: b.id, payload: { type: 'hello', x: 1 },
  });
  const relayed = take(b, 'mmo.relay');
  ok(relayed && relayed.payload && relayed.payload.type === 'hello',
    'trade mmo.relay still forwards unread');
}

function testCoopWildSeating() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'CWILDA');
  const b = dial(relay, 'CWILDB');

  const record = relay.openMediatedBattle('cw-1', {
    mode: 'coop_wild',
    hostId: a.id,
    memberIds: [a.id, b.id],
  });
  ok(record && record.npcIds.length === 1,
    'coop_wild opens with one synthetic wild seat');
  ok(record.sides.a.length === 2 && record.sides.b.length === 1,
    'side a is two humans and side b is the wild seat');
  ok(record.sides.b[0] === record.npcIds[0],
    'side b names the wild seat');
  ok(relay.battleSeat(record, relay.get(a.id), { side: 'b' }) === record.npcIds[0],
    "the host's side-b upload fills the wild seat");

  const solo = relay.openMediatedBattle('cw-2', {
    mode: 'coop_wild',
    hostId: a.id,
    memberIds: [a.id],
    eligibleIds: [a.id],
  });
  ok(solo && solo.sides.a.length === 1,
    'coop_wild may begin with a vacant second human seat');

  const c = dial(relay, 'CWILDC');
  const crowd = relay.openMediatedBattle('cw-3', {
    mode: 'coop_wild',
    hostId: a.id,
    memberIds: [a.id, b.id, c.id],
  });
  ok(crowd === null, 'coop_wild refuses with three humans');
}

function testFlexibleWildAdmissionBoundary() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'FLEXA');
  const b = dial(relay, 'FLEXB');
  const record = relay.openMediatedBattle('cw-flex', {
    mode: 'coop_wild', hostId: a.id, memberIds: [a.id],
    eligibleIds: [a.id, b.id],
  });
  relay.fillBattleParty(record, relay.get(a.id), {
    battle: 'cw-flex', side: 'a', mons: [mon(1, 999)], bag: [],
  });
  relay.fillBattleParty(record, relay.get(a.id), {
    battle: 'cw-flex', side: 'b', mons: [mon(1, 999)], bag: [],
  });
  record.ruleset = { chart: [[100]] };
  ok(relay.tryStartSim(record), 'one-human flexible Wild starts immediately');
  ok(record.history.length > 0, 'the hub retains the authoritative opening stream');
  ok(record.history.at(-1).seq === record.sim.seq,
    'retained history reaches the latest drained sequence');
  record.packedField = {
    flexibleWild: true,
    slots: [
      { side: 'a', owner: a.id, name: a.name, party: [{ species: 'HOST' }] },
      { side: 'b', name: 'WILD', party: [{ species: 'WILD' }] },
    ],
  };
  record.encounterOffer = { battle: 'ROUTE_1|WILD', map: 'ROUTE_1' };
  record.packedParties.set(b.id, [{ species: 'JOINER' }]);
  b.peer.outbox = [];
  ok(relay.sendLateBattleField(record, relay.get(b.id)),
    'the entrant receives an expanded packed field');
  const fieldMsg = take(b, 'mmo.coop_msg');
  ok(fieldMsg.payload.field.slots.length === 3,
    'the expanded field adds exactly one ally slot');
  b.peer.outbox = [];
  ok(relay.sendBattleCatchup(record, relay.get(b.id)),
    'the entrant receives a replay baseline');
  ok(b.peer.outbox[0].type === 'mmo.battle_ready', 'ready precedes replayed events');
  ok(b.peer.outbox[0].catchup === true,
    'the replay baseline suppresses historical self-departure');
  ok(b.peer.outbox.length - 1 === record.history.length,
    'the complete retained history follows ready');
  b.peer.outbox = [];
  record.sim.drainEvents();
  ok(record.sim.submitChoice(a.id, { action: 'fight', move: 0 }),
    'the host closes the prefilled opening turn');
  ok(record.sim.submitChoice(a.id, { action: 'fight', move: 0 }),
    'the host commits on the next turn before late admission');
  ok(relay.queueBattleAdmission(record, relay.get(b.id), {
    battle: 'cw-flex', side: 'a', mons: [mon(10)], bag: [],
  }) === false, 'late admission queues after a committed choice');
  ok(record.pendingAdmissions.has(b.id), 'the queued party is retained');
  a.peer.outbox = [];
  b.peer.outbox = [];
  relay.flushBattle(record);
  ok(!record.pendingAdmissions.has(b.id), 'the next clean boundary admits it');
  ok(record.sides.a[1] === b.id, 'the late player joins side a');
  ok(record.sim.byId.get(b.id).slot === 1, 'the stable second field slot is assigned');
  ok(a.peer.outbox[0].type === 'mmo.battle_seat',
    'the existing screen learns the new engine party before admission events');
  ok(a.peer.outbox[1].type === 'mmo.battle_ready',
    'the refreshed mediated mapping follows the dynamic seat');
  ok(b.peer.outbox[0].type === 'mmo.battle_seat',
    'the entrant receives the same admission boundary');
  ok(b.peer.outbox[1].type === 'mmo.battle_ready',
    'the entrant remaps its hydrated screen before live events');

  a.peer.outbox = [];
  b.peer.outbox = [];
  ok(record.sim.submitChoice(b.id, { action: 'run' }),
    'the late ally may independently choose to flee');
  ok(record.sim.submitChoice(a.id, { action: 'fight', move: 0 }),
    'the survivor answers the same turn');
  ok(record.sim.autoPick(record.npcIds[0]), 'the Wild closes the flee turn');
  relay.flushBattle(record);
  ok(record.sim.byId.get(b.id).present === false,
    'independent flee vacates only that stable seat');
  ok(relay.get(b.id).coopBattleId === null, 'the runner is no longer presence-busy');
  ok(relay.get(a.id).coopOffer.plan === record.id, 'the survivor owns a rejoin offer');
  const reoffer = take(b, 'mmo.coop_offer');
  ok(reoffer && reoffer.battle === 'ROUTE_1|WILD',
    'the runner can explicitly rejoin the same encounter');

  ok(relay.queueBattleAdmission(record, relay.get(b.id), {
    battle: record.id, side: 'a', mons: [mon(10)],
  }) === false, 'the former runner queues behind the Wild automatic choice');
  ok(record.sim.submitChoice(a.id, { action: 'fight', move: 0 }),
    'the survivor closes that already-open turn');
  relay.flushBattle(record);
  ok(record.sim.byId.get(b.id).present === true,
    'the queued runner rejoins at the next pristine boundary');
  ok(record.sim.submitChoice(a.id, { action: 'run' }),
    'the original host may later leave independently');
  ok(record.sim.submitChoice(b.id, { action: 'fight', move: 0 }),
    'the surviving player carries the encounter');
  if (record.sim._owes(record.sim.byId.get(record.npcIds[0]))) {
    ok(record.sim.autoPick(record.npcIds[0]), 'the Wild closes the transfer turn');
  }
  relay.flushBattle(record);
  ok(record.hostId === b.id, 'encounter authority transfers to the survivor');
  ok(record.hostGeneration === 2, 'host transfer advances its generation');
  ok(record.hostHistory.join(',') === `${a.id},${b.id}`,
    'host transfer appends to the reconstructable authority history');
}

function testFlexibleWildBootstrapCapture() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'BOOT');
  relay.openCoopBattle('cw-bootstrap', [a.id], {
    mode: 'coop_wild', hostId: a.id, eligibleIds: [a.id],
  });
  relay.handle(a.id, {
    type: 'mmo.coop_relay', payload: { t: 'party', mons: [{ species: 'PACKED' }] },
  });
  relay.handle(a.id, {
    type: 'mmo.coop_relay', payload: { t: 'field', field: { slots: [{ side: 'a' }] } },
  });
  const record = relay.battles.get('cw-bootstrap');
  ok(record.packedParties.get(a.id)[0].species === 'PACKED',
    'the Node hub retains the engine-packed human bootstrap');
  ok(record.packedField.slots[0].side === 'a',
    "and retains the host's packed initial field");
}

function testFlexibleWildSecondTarget() {
  const relay = new Relay({ maxPlayers: 4, wildDoubleRate: 100 });
  const a = dial(relay, 'DOUBLEA');
  const b = dial(relay, 'DOUBLEB');
  const record = relay.openMediatedBattle('cw-double', {
    mode: 'coop_wild', hostId: a.id, memberIds: [a.id],
    eligibleIds: [a.id, b.id],
  });
  relay.fillBattleParty(record, relay.get(a.id), {
    battle: record.id, side: 'a', mons: [mon(10)], bag: [],
  });
  relay.fillBattleParty(record, relay.get(a.id), {
    battle: record.id, side: 'b', mons: [mon(10)], bag: [],
  });
  record.ruleset = { chart: [[100]] };
  relay.tryStartSim(record);
  record.reservedWild = [mon(10)];
  record.packedWild = [{ species: 'PACKED_WILD2' }];
  b.peer.outbox = [];
  ok(relay.queueBattleAdmission(record, relay.get(b.id), {
    battle: record.id, side: 'a', mons: [mon(10)], bag: [],
  }) === false, "the admission waits behind the Wild's prefilled opening choice");
  record.sim.submitChoice(a.id, { action: 'fight', move: 0 });
  relay.flushBattle(record);
  ok(record.sides.b.length === 2, 'the authoritative field gains one second Wild');
  ok(record.sim.bySide.b.length === 2, 'the Node turn machine owns both Wild targets');
  const seat = take(b, 'mmo.battle_seat');
  ok(seat && seat.synthetic === true, 'the dynamic foe is ownerless on clients');
}

function testCoopWildCatchCatcher() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'CATCHA');
  const b = dial(relay, 'CATCHB');
  relay.openCoopBattle('cw-catch', [a.id, b.id],
    { mode: 'coop_wild', hostId: a.id });
  const record = relay.battles.get('cw-catch');
  a.peer.outbox = [];
  b.peer.outbox = [];

  relay.handle(a.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'cw-catch',
    side: 'a',
    mons: [mon(90)],
    bag: [{ id: 'MASTER_BALL', count: 1 }],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party',
    battle: 'cw-catch',
    side: 'a',
    mons: [mon(90)],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'cw-catch',
    side: 'b',
    mons: [{
      species: 'PIDGEY',
      level: 50,
      hp: 100,
      maxHp: 100,
      catchRate: 255,
      stats: { atk: 40, def: 40, spd: 40, spc: 40 },
      moves: [{
        id: 'm1', pp: 15, power: 0, accuracy: 255, type: 0, effect: 0, chance: 0,
      }],
    }],
  });
  ok(record && record.sim, 'coop_wild sim starts with two humans and a wild party');
  take(a, 'mmo.battle_ready');
  take(b, 'mmo.battle_ready');
  a.peer.outbox = [];
  b.peer.outbox = [];

  let outcome = null;
  for (let turn = 0; turn < 20; turn += 1) {
    takeAll(a, 'mmo.battle_event');
    takeAll(b, 'mmo.battle_event');
    if (!relay.battles.has('cw-catch')) break;
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: 'cw-catch',
      action: 'item', item: 'MASTER_BALL',
    });
    relay.handle(b.id, {
      type: 'mmo.battle_choice', battle: 'cw-catch',
      action: 'fight', move: 0,
    });
    outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
    if (outcome) break;
  }
  ok(outcome && outcome.reason === 'catch',
    'catch success reasons the outcome as catch');
  ok(outcome.catcher === a.id, 'catcher names the thrower');
  ok(take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome'),
    'both players hear the outcome');
  ok(!relay.battles.has('cw-catch'),
    'the record is cleared like any other settlement');
}

function testBagProofs() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'BAGA');
  const b = dial(relay, 'BAGB');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];

  relay.handle(a.id, {
    type: 'mmo.battle_ruleset', chart: [[100]],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: [mon(40)],
    bag: [{ id: 'NOT_A_REAL_ITEM', count: 1 }],
  });
  ok(!relay.battles.get(session.id).parties.has(a.id),
    'unknown bag id refuses the party');
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: [mon(40)],
    bag: [{ id: 'POTION', count: 1 }, { id: 'POKE_FLUTE', count: 1 }],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: [mon(100)],
  });
  const record = relay.battles.get(session.id);
  ok(record && record.sim, 'fight opens with bag sheets');
  ok(record.bags.get(a.id).POTION === 1, "host's bag holds one potion");
  ok(!record.bags.get(b.id).POTION, 'guest empty bag has no potion');

  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: session.id,
    action: 'item', item: 'POTION',
  });
  ok(record.sim.byId.get(b.id).choice == null,
    'item without a bag stack is refused');

  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: session.id,
    action: 'item', item: 'POTION',
  });
  ok(record.sim.byId.get(a.id).choice != null, 'proved potion accepted');
  ok(record.bags.get(a.id).POTION === 1, 'stack held until resolve');
  ok(record.bagHold[a.id] === 'POTION', 'hold names the pending item');

  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: session.id, action: 'cancel',
  });
  ok(record.sim.byId.get(a.id).choice == null, 'cancel clears the choice');
  ok(record.bagHold[a.id] === undefined, 'and drops the bag hold');
  ok(record.bags.get(a.id).POTION === 1, 'without decrementing');

  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: session.id,
    action: 'item', item: 'POTION',
  });
  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: session.id,
    action: 'fight', move: 0,
  });
  ok(record.bags.get(a.id).POTION === undefined, 'resolve spends the hold');

  if (record.sim && record.sim.phase === 'choice') {
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: session.id,
      action: 'item', item: 'POTION',
    });
    ok(record.sim.byId.get(a.id).choice == null,
      'overdrawn potion refused');
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: session.id,
      action: 'item', item: 'POKE_FLUTE',
    });
    ok(record.sim.byId.get(a.id).choice != null, 'Poké Flute proved');
    ok(record.bags.get(a.id).POKE_FLUTE === 1,
      'Poké Flute not decremented');
  }
}

testMediatedOneVOneKo();
testRelayHardCutDuringBattle();
testDisconnectForfeitAfterGrace();
testDrawCarriesNoLists();
testCoopNpcMediated();
testCoopWildSeating();
testFlexibleWildAdmissionBoundary();
testFlexibleWildSecondTarget();
testFlexibleWildBootstrapCapture();
testCoopWildCatchCatcher();
testTradeRelayStillWorks();
testBagProofs();

console.log(`hub_battle: ${passed} checks passed`);
