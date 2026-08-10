'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { cleanConvoy } = require('./lib/sanitize');
const { Relay, PROTOCOL } = require('./lib/relay');

function peer() {
  return { messages: [], send(message) { this.messages.push(message); }, close() {} };
}

test('convoy sanitizer is bounded and presentation-only', () => {
  const rows = Array.from({ length: 8 }, (_, i) => ({
    species: `MON_${i}`, map: 'ROUTE_1', x: i, y: 5, facing: 'right',
    hp: 99, moves: ['TACKLE'],
  }));
  rows[1].species = 'bad value';
  const clean = cleanConvoy(rows);
  assert.equal(clean.length, 6);
  assert.equal(clean[0].species, 'MON_0');
  assert.equal(clean[0].hp, undefined);
  assert.equal(clean[0].moves, undefined);
});

test('relay sanitizes convoy on hello and move', () => {
  const relay = new Relay({ protocol: PROTOCOL, log: { debug() {}, info() {}, warn() {} } });
  const ann = peer();
  const annId = relay.accept(ann);
  relay.handle(annId, { type: 'mmo.hello', proto: PROTOCOL, name: 'ANN',
    map: 'ROUTE_1', x: 1, y: 1,
    convoy: [{ species: 'PIKACHU', x: 0, y: 1, hp: 20 }] });
  assert.equal(relay.clients.get(annId).convoy[0].hp, undefined);
  relay.handle(annId, { type: 'mmo.move', map: 'ROUTE_1', x: 2, y: 1,
    convoy: [{ species: 'EEVEE', x: 1, y: 1, nickname: 'PRIVATE' }] });
  assert.equal(relay.clients.get(annId).convoy[0].species, 'EEVEE');
  assert.equal(relay.clients.get(annId).convoy[0].nickname, undefined);
});
