'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { cleanCoopOfferMode } = require('./lib/sanitize');

test('campaign trainer offer mode is closed and transport-safe', () => {
  assert.equal(cleanCoopOfferMode('campaign_trainer'), 'campaign_trainer');
  assert.equal(cleanCoopOfferMode('coop_wild'), 'coop_wild');
  assert.equal(cleanCoopOfferMode('automatic'), null);
});
