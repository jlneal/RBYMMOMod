'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  cleanWorldFrontier, cleanWorldGrantBase, cleanWorldFrontierAdmission,
} = require('./lib/campaign-sanitize.js');

const A = 'a'.repeat(16);
const R = 'b'.repeat(16);
const D = 'c'.repeat(16);
const T = 'd'.repeat(64);
const frontier = () => ({ version: 1, world: 'shared-kanto',
  compatibility: 'campaign-state.4.proof', timelineHead: 3,
  canonicalDigest: D, heads: { ann: 7, bob: 2 }, revision: R, tag: T });
const base = () => ({ version: 1, world: 'shared-kanto',
  compatibility: 'campaign-state.4.proof', position: 4, baseDigest: D,
  authorityRevision: A, replicaRevision: R });

test('protocol-19 frontier vocabulary matches the Lua boundary', () => {
  assert.equal(cleanWorldFrontier(frontier()).timelineHead, 3);
  assert.equal(cleanWorldGrantBase(base()).position, 4);
  assert.equal(cleanWorldFrontierAdmission({ frontier: frontier(),
    authorityRevision: A, replicaRevision: R, grantBase: base() })
    .replicaRevision, R);

  let bad = frontier(); bad.version = 2;
  assert.equal(cleanWorldFrontier(bad), null);
  bad = frontier(); bad.timelineHead = 4097;
  assert.equal(cleanWorldFrontier(bad), null);
  bad = frontier(); bad.timelineHead = '3';
  assert.equal(cleanWorldFrontier(bad), null);
  bad = frontier(); bad.timelineHead = 3.5;
  assert.equal(cleanWorldFrontier(bad), null);
  bad = frontier(); bad.revision = 'g'.repeat(16);
  assert.equal(cleanWorldFrontier(bad), null);
  bad = frontier(); bad.tag = 'a'.repeat(63);
  assert.equal(cleanWorldFrontier(bad), null);
  bad = frontier(); bad.heads.eve = Infinity;
  assert.equal(cleanWorldFrontier(bad), null);
  bad = frontier(); bad.heads.eve = '1';
  assert.equal(cleanWorldFrontier(bad), null);
  bad = frontier(); bad.heads = Object.fromEntries(
    Array.from({ length: 65 }, (_, index) => [`actor${index + 1}`, index + 1]));
  assert.equal(cleanWorldFrontier(bad), null);

  bad = base(); bad.position = 0;
  assert.equal(cleanWorldGrantBase(bad), null);
  bad = base(); bad.position = 4.5;
  assert.equal(cleanWorldGrantBase(bad), null);
  bad = base(); bad.baseDigest = '0'.repeat(15);
  assert.equal(cleanWorldGrantBase(bad), null);
  bad = base(); bad.compatibility = 'bad compatibility';
  assert.equal(cleanWorldGrantBase(bad), null);

  let row = { frontier: frontier(), authorityRevision: 'e'.repeat(16),
    replicaRevision: R, grantBase: base() };
  assert.equal(cleanWorldFrontierAdmission(row), null);
  row = { frontier: frontier(), authorityRevision: A,
    replicaRevision: 'e'.repeat(16), grantBase: base() };
  assert.equal(cleanWorldFrontierAdmission(row), null);
  row = { frontier: frontier(), authorityRevision: A,
    replicaRevision: R, grantBase: base() };
  row.grantBase.position = 5;
  assert.equal(cleanWorldFrontierAdmission(row), null);
  row = { frontier: frontier(), authorityRevision: A,
    replicaRevision: R, grantBase: base() };
  row.grantBase.world = 'other-world';
  assert.equal(cleanWorldFrontierAdmission(row), null);
});
