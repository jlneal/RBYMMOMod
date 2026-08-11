'use strict';

const assert = require('node:assert/strict');
const { Relay, PROTOCOL } = require('./lib/relay');

function pair(enabled, offMapJoinEnabled = false, splitMaps = false) {
  const relay = new Relay({ maxPlayers: 4, proximityJoinEnabled: enabled,
    offMapJoinEnabled });
  const peers = [{ outbox: [] }, { outbox: [] }];
  const ids = peers.map((peer, index) => {
    peer.send = (message) => peer.outbox.push(message);
    peer.close = () => {};
    const id = relay.accept(peer);
    relay.handle(id, {
      type: 'mmo.hello', proto: PROTOCOL, name: index ? 'BLUE' : 'RED',
      playerId: index ? 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        : 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      map: splitMaps && index ? 'ROUTE_1' : 'PALLET_TOWN',
    });
    return messages(peer, 'mmo.welcome')[0].id;
  });
  relay.parties.set('party', ids.slice());
  for (const id of ids) relay.clients.get(id).partyId = 'party';
  return { relay, peers, ids };
}

{
  const { relay, peers, ids } = pair(true, false, true);
  relay.handle(ids[0], {
    type: 'mmo.coop_wait', battle: 'PALLET_TOWN|PIDGEY',
    map: 'PALLET_TOWN', mode: 'coop_wild',
  });
  assert.equal(messages(peers[1], 'mmo.coop_offer').length, 0);
  const plan = relay.get(ids[0]).coopOffer.plan;
  assert.deepEqual(Array.from(relay.battles.get(plan).eligibleIds), [ids[0]]);
}

{
  const { relay, peers, ids } = pair(true, true, true);
  relay.handle(ids[0], {
    type: 'mmo.coop_wait', battle: 'PALLET_TOWN|PIDGEY',
    map: 'PALLET_TOWN', mode: 'coop_wild',
  });
  assert.equal(messages(peers[1], 'mmo.coop_offer').length, 1);
  const plan = relay.get(ids[0]).coopOffer.plan;
  assert.deepEqual(Array.from(relay.battles.get(plan).eligibleIds), ids);
}

function messages(peer, type) {
  return peer.outbox.filter((message) => message.type === type);
}

{
  const { relay, peers, ids } = pair(false);
  const welcome = messages(peers[1], 'mmo.welcome')[0];
  assert.equal(welcome.proximityJoinEnabled, false);
  relay.handle(ids[0], { type: 'mmo.coop_wait', battle: 'ROUTE_1|TRAINER' });
  relay.handle(ids[1], {
    type: 'mmo.coop_join', to: ids[0], battle: 'ROUTE_1|TRAINER', auto: true,
  });
  assert.equal(messages(peers[1], 'mmo.coop_battle').length, 0);
  relay.handle(ids[1], {
    type: 'mmo.coop_join', to: ids[0], battle: 'ROUTE_1|TRAINER',
  });
  assert.equal(messages(peers[1], 'mmo.coop_battle').length, 1);
}

{
  const { relay, peers, ids } = pair(true);
  assert.equal(messages(peers[1], 'mmo.welcome')[0].proximityJoinEnabled, true);
  relay.handle(ids[0], { type: 'mmo.coop_wait', battle: 'ROUTE_1|TRAINER' });
  relay.handle(ids[1], {
    type: 'mmo.coop_join', to: ids[0], battle: 'ROUTE_1|TRAINER', auto: true,
  });
  assert.equal(messages(peers[1], 'mmo.coop_battle').length, 1);
}

{
  const { relay, peers, ids } = pair(true);
  relay.wildCoopEnabled = false;
  relay.handle(ids[0], {
    type: 'mmo.coop_wait', battle: 'ROUTE_1|PIDGEY', mode: 'coop_wild',
  });
  assert.equal(messages(peers[1], 'mmo.coop_offer').length, 0);
}

console.log('proximity policy relay: 12 passed');
