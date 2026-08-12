'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { start, CAMPAIGN_FILENAME } = require('./lib/server');

const quiet = { debug() {}, info() {}, warn() {}, error() {} };
const config = { listen: { host: '127.0.0.1', port: 0 }, maxPlayers: 2,
  auth: { required: false, credentials: [] } };

function join(relay) {
  const peer = { outbox: [], remoteAddress: '127.0.0.1',
    send(message) { this.outbox.push(message); }, close() {} };
  const id = relay.accept(peer);
  relay.handle(id, { type: 'mmo.hello', proto: relay.protocol, name: 'ANN',
    playerId: '1'.repeat(32), map: 'PALLET', x: 1, y: 1, facing: 'down' });
  return { id: '1'.repeat(32), peer };
}

test('dedicated server atomically persists and reloads campaign canon', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-campaign-store-'));
  const configPath = path.join(dir, 'config.json');
  fs.writeFileSync(configPath, JSON.stringify(config));
  const first = await start({ config, configPath, log: quiet,
    handleSignals: false, allowUnauthenticated: true });
  const side = join(first.relay);
  const world = 'persisted-world'; const compatibility = 'campaign-state.4.durable';
  const tag = 'a'.repeat(64);
  const frontier = { version: 1, world, compatibility, timelineHead: 0,
    canonicalDigest: 'b'.repeat(16), heads: {}, revision: 'c'.repeat(16), tag };
  const inventory = { schema: 1, world, compatibility, player: 'ann',
    timelineHead: 0, heads: {}, tag };
  first.relay.handle(side.id, { type: 'mmo.world_archive_begin',
    inventory, frontier, batches: 0 });
  first.relay.handle(side.id, { type: 'mmo.world_archive_end', world,
    compatibility, revision: frontier.revision });
  await first.close();
  const stored = JSON.parse(fs.readFileSync(path.join(dir, CAMPAIGN_FILENAME)));
  assert.equal(stored.worlds[0].frontier.revision, frontier.revision);

  const second = await start({ config, configPath, log: quiet,
    handleSignals: false, allowUnauthenticated: true });
  assert.equal(second.relay.worldTimelines.get(`${world}|${compatibility}`)
    .frontier.revision, frontier.revision);
  await second.close();
});

test('dedicated server fails closed on a corrupt campaign database', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-campaign-corrupt-'));
  const configPath = path.join(dir, 'config.json');
  fs.writeFileSync(configPath, JSON.stringify(config));
  fs.writeFileSync(path.join(dir, CAMPAIGN_FILENAME), '{broken');
  const handle = await start({ config, configPath, log: quiet,
    handleSignals: false, allowUnauthenticated: true });
  assert.equal(handle.relay.campaignArchiveCorrupt, true);
  await handle.close();
  assert.equal(fs.readFileSync(path.join(dir, CAMPAIGN_FILENAME), 'utf8'), '{broken',
    'shutdown does not replace corrupt canon with an empty archive');
});
