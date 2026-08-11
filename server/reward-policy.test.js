'use strict';

const assert = require('node:assert/strict');
const { Relay, PROTOCOL } = require('./lib/relay');

function welcome(options) {
  const relay = new Relay(Object.assign({ maxPlayers: 4 }, options));
  const sent = [];
  const id = relay.accept({
    send: (message) => sent.push(message), close: () => {},
  });
  relay.handle(id, {
    type: 'mmo.hello', proto: PROTOCOL, name: 'RED',
    playerId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });
  return sent.find((message) => message.type === 'mmo.welcome');
}

const defaults = welcome();
assert.equal(defaults.coopExpEnabled, true);
assert.equal(defaults.coopMoneyEnabled, true);
assert.equal(defaults.wildCoopEnabled, true);
assert.equal(defaults.wildDoubleRate, 0);
assert.equal(defaults.offMapJoinEnabled, false);
assert.equal(defaults.proximityJoinEnabled, true);

const disabled = welcome({ coopExpEnabled: false, coopMoneyEnabled: false });
assert.equal(disabled.coopExpEnabled, false);
assert.equal(disabled.coopMoneyEnabled, false);

const split = welcome({ coopExpEnabled: false, coopMoneyEnabled: true });
assert.equal(split.coopExpEnabled, false);
assert.equal(split.coopMoneyEnabled, true);

const gameplay = welcome({
  wildCoopEnabled: false, wildDoubleRate: 35, offMapJoinEnabled: true,
  proximityJoinEnabled: false,
});
assert.equal(gameplay.wildCoopEnabled, false);
assert.equal(gameplay.wildDoubleRate, 35);
assert.equal(gameplay.offMapJoinEnabled, true);
assert.equal(gameplay.proximityJoinEnabled, false);

console.log('gameplay policy relay: 14 passed');
