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
  });
  return sent.find((message) => message.type === 'mmo.welcome');
}

const defaults = welcome();
assert.equal(defaults.coopExpEnabled, true);
assert.equal(defaults.coopMoneyEnabled, true);

const disabled = welcome({ coopExpEnabled: false, coopMoneyEnabled: false });
assert.equal(disabled.coopExpEnabled, false);
assert.equal(disabled.coopMoneyEnabled, false);

const split = welcome({ coopExpEnabled: false, coopMoneyEnabled: true });
assert.equal(split.coopExpEnabled, false);
assert.equal(split.coopMoneyEnabled, true);

console.log('reward policy relay: 6 passed');
