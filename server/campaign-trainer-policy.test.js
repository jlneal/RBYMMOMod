'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { cleanBattleContext, cleanCoopOfferMode } = require('./lib/sanitize');

test('campaign trainer offer mode is closed and transport-safe', () => {
  assert.equal(cleanCoopOfferMode('campaign_trainer'), 'campaign_trainer');
  assert.equal(cleanCoopOfferMode('coop_wild'), 'coop_wild');
  assert.equal(cleanCoopOfferMode('automatic'), null);
});

test('paired opponent recipes are bounded and owner-bearing', () => {
  const context = cleanBattleContext({ occurrence: 'rby:route22:1',
    definition: '0123456789abcdef', requirements: {
      joinPolicy: 'automatic-second-slot', enrollmentCutoff: 'resolution',
      fleeAllowed: false, opponentPolicy: 'paired-rival', opponent: {
        trainerClass: 'RBY_SHARED_RIVAL1', partyIndex: 8,
        owner: 'bob', rival: 'rby:rival-for:bob',
      },
    } });
  assert.equal(context.requirements.opponent.owner, 'bob');
  assert.equal(cleanBattleContext({ occurrence: 'rby:route22:1',
    definition: '0123456789abcdef', requirements: {} }), null);
});
