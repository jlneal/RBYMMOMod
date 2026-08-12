'use strict';

const { randomBytes } = require('node:crypto');
const { isDeepStrictEqual } = require('node:util');
const { cleanId } = require('./sanitize');
const {
  cleanWorldInventory, cleanWorldBatch, cleanWorldInvitation,
  cleanWorldArchiveBegin, cleanWorldArchiveEnd,
  cleanWorldClosedPackage,
  cleanWorldPrefixFrame, cleanWorldPrefixFrameAck,
  cleanWorldSequenceRequest, cleanWorldSequenceGrant,
  cleanWorldSequenceCancel, cleanWorldFrontier, cleanWorldGrantBase,
  cleanWorldFrontierAdmission,
} = require('./campaign-sanitize');

const handlers = Object.create(null);

function sameWorld(a, b) {
  return Boolean(a && b && a.world === b.world
    && a.compatibility === b.compatibility);
}

function sameHeads(a, b) {
  if (!a || !b || typeof a !== 'object' || typeof b !== 'object') return false;
  const left = Object.keys(a); const right = Object.keys(b);
  if (left.length !== right.length) return false;
  return left.every((actor) => b[actor] === a[actor]);
}

function inventoryMatchesFrontier(inventory, frontier) {
  return sameWorld(inventory, frontier)
    && inventory.timelineHead === frontier.timelineHead
    && sameHeads(inventory.heads, frontier.heads);
}

function sameFrontier(a, b) {
  return sameWorld(a, b) && a.revision === b.revision
    && a.timelineHead === b.timelineHead
    && a.canonicalDigest === b.canonicalDigest
    && sameHeads(a.heads, b.heads);
}

function advancesOwnActorHead(current, candidate, actor) {
  if (!current || !candidate || !actor || !sameWorld(current, candidate)
      || candidate.timelineHead !== current.timelineHead
      || candidate.canonicalDigest !== current.canonicalDigest) return false;
  let advanced = false;
  for (const [id, seq] of Object.entries(current.heads)) {
    const nextSeq = candidate.heads[id];
    if (nextSeq === undefined) return false;
    if (id === actor) {
      if (nextSeq < seq) return false;
      if (nextSeq > seq) advanced = true;
    } else if (nextSeq !== seq) return false;
  }
  return Object.keys(candidate.heads).every((id) => current.heads[id] !== undefined)
    && advanced;
}

const WORLD_EVIDENCE_LIMIT = 4096;

function notifyArchiveChange(relay) {
  if (typeof relay.onCampaignChange !== 'function') return true;
  return relay.onCampaignChange(exportArchive(relay)) !== false;
}

function recordArchiveEnvelope(state, envelope) {
  if (!state.archiveEnvelopes) state.archiveEnvelopes = new Map();
  if (!state.archiveEvents) state.archiveEvents = new Map();
  for (const event of envelope.events) {
    const previous = state.archiveEvents.get(event.id);
    if (previous && !isDeepStrictEqual(previous, event)) return false;
  }
  for (const event of envelope.events) state.archiveEvents.set(event.id, event);
  state.archiveEnvelopes.set(envelope.tag, envelope);
  recordWorldEvidence(state, envelope.events);
  return true;
}

function archiveCovers(frontier, events) {
  for (const [actor, head] of Object.entries(frontier.heads)) {
    for (let seq = 1; seq <= head; seq += 1) {
      if (!events.has(`${actor}:${seq}`)) return false;
    }
  }
  const positions = new Set();
  for (const event of events.values()) {
    if (event.owner === 'world' && event.position !== undefined) positions.add(event.position);
  }
  for (let position = 1; position <= frontier.timelineHead; position += 1) {
    if (!positions.has(position)) return false;
  }
  return true;
}

function exportArchive(relay) {
  return { schema: 1, worlds: [...relay.worldTimelines.values()].map((state) => ({
    world: state.world, compatibility: state.compatibility,
    frontier: state.frontier,
    envelopes: [...(state.archiveEnvelopes || new Map()).values()],
  })) };
}

function importArchive(relay, raw) {
  if (!raw) return true;
  if (raw.schema !== 1 || !Array.isArray(raw.worlds)) return false;
  for (const row of raw.worlds) {
    const frontier = cleanWorldFrontier(row && row.frontier);
    if (!frontier || row.world !== frontier.world
        || row.compatibility !== frontier.compatibility
      || !Array.isArray(row.envelopes)) return false;
    const state = makeWorldState(frontier, frontier);
    let valid = true;
    for (const rawEnvelope of row.envelopes) {
      const envelope = cleanWorldBatch(rawEnvelope);
      if (!envelope || !sameWorld(envelope, frontier)
          || !recordArchiveEnvelope(state, envelope)) { valid = false; break; }
    }
    if (!valid || !archiveCovers(frontier, state.archiveEvents)) return false;
    rebuildUncommittedEvidence(state);
    relay.worldTimelines.set(state.key, state);
  }
  return true;
}

function recordWorldEvidence(state, events) {
  for (const event of events) {
    if (state.evidenceIds.has(event.id)
        || state.evidenceCount >= WORLD_EVIDENCE_LIMIT) continue;
    const row = { actor: event.actor, seq: event.seq,
      position: event.owner === 'world' ? event.position : undefined };
    state.evidenceIds.set(event.id, row);
    state.evidenceCount += 1;
    let actor = state.evidenceActors.get(row.actor);
    if (!actor) { actor = new Set(); state.evidenceActors.set(row.actor, actor); }
    actor.add(row.seq);
    if (row.position !== undefined) state.evidencePositions.add(row.position);
  }
}

function pruneWorldEvidence(state) {
  if (!state.frontier) return;
  for (const [id, row] of state.evidenceIds) {
    const actorHead = state.frontier.heads[row.actor] || 0;
    if (row.seq <= actorHead && (row.position === undefined
        || row.position <= state.frontier.timelineHead)) {
      state.evidenceIds.delete(id);
      state.evidenceCount -= 1;
      const actor = state.evidenceActors.get(row.actor);
      if (actor) actor.delete(row.seq);
      if (row.position !== undefined) state.evidencePositions.delete(row.position);
    }
  }
}

function rebuildUncommittedEvidence(state) {
  state.evidenceIds = new Map(); state.evidenceActors = new Map();
  state.evidencePositions = new Set(); state.evidenceCount = 0;
  for (const envelope of (state.archiveEnvelopes || new Map()).values()) {
    recordWorldEvidence(state, envelope.events.filter((event) =>
      event.seq > (state.frontier.heads[event.actor] || 0)
      || (event.position !== undefined
        && event.position > state.frontier.timelineHead)));
  }
}

function advancesFromRelayedEvidence(state, candidate, localActor) {
  const current = state.frontier;
  if (!current || state.pending || !state.evidenceCount
      || !sameWorld(current, candidate)
      || candidate.timelineHead < current.timelineHead) return false;
  let changed = candidate.timelineHead > current.timelineHead;
  if (candidate.timelineHead === current.timelineHead) {
    if (candidate.canonicalDigest !== current.canonicalDigest) return false;
  } else {
    for (let position = current.timelineHead + 1;
      position <= candidate.timelineHead; position += 1) {
      if (!state.evidencePositions.has(position)) return false;
    }
  }
  for (const [actor, seq] of Object.entries(current.heads)) {
    const nextSeq = candidate.heads[actor];
    if (nextSeq === undefined || nextSeq < seq) return false;
  }
  for (const [actor, nextSeq] of Object.entries(candidate.heads)) {
    const seq = current.heads[actor] || 0;
    if (nextSeq > seq) {
      changed = true;
      if (actor !== localActor) {
        if (nextSeq - seq > WORLD_EVIDENCE_LIMIT) return false;
        const evidence = state.evidenceActors.get(actor);
        for (let expected = seq + 1; expected <= nextSeq; expected += 1) {
          if (!evidence || !evidence.has(expected)) return false;
        }
      }
    }
  }
  return changed;
}

function sameGrantBase(a, b) {
  return Boolean(a && b && a.version === b.version && a.world === b.world
    && a.compatibility === b.compatibility && a.position === b.position
    && a.baseDigest === b.baseDigest
    && a.authorityRevision === b.authorityRevision
    && a.replicaRevision === b.replicaRevision);
}

function makeWorldState(inventory, frontier = null) {
  const key = `${inventory.world}|${inventory.compatibility}`;
  return { key, world: inventory.world, compatibility: inventory.compatibility,
    head: inventory.timelineHead, frontier,
    evidenceIds: new Map(), evidenceActors: new Map(),
    evidencePositions: new Set(), evidenceCount: 0,
    archiveEnvelopes: new Map(), archiveEvents: new Map(),
    pending: null, queue: [], requests: new Set() };
}

function worldTimeline(relay, inventory, frontier = null) {
  const key = `${inventory.world}|${inventory.compatibility}`;
  let state = relay.worldTimelines.get(key);
  if (!state) {
    state = makeWorldState(inventory, relay.protocol >= 19 ? frontier : null);
    relay.worldTimelines.set(key, state);
  } else if (relay.protocol < 19 && !state.pending
      && inventory.timelineHead > state.head) {
    state.head = inventory.timelineHead;
  }
  return state;
}

function sendAuthorityFrontier(relay, client, state) {
  if (relay.protocol >= 19 && state.frontier) {
    relay.send(client, 'mmo.world_frontier', { frontier: state.frontier });
  }
}

function replicaIsBehind(replica, authority) {
  if (!sameWorld(replica, authority)
      || replica.timelineHead > authority.timelineHead) return false;
  for (const [actor, seq] of Object.entries(replica.heads)) {
    if (seq > (authority.heads[actor] || 0)) return false;
  }
  return replica.timelineHead < authority.timelineHead
    || Object.entries(authority.heads)
      .some(([actor, seq]) => (replica.heads[actor] || 0) < seq);
}

function sendArchiveCatchup(relay, client, state, inventory) {
  if (!replicaIsBehind(inventory, state.frontier)) return false;
  const needed = new Set();
  for (const [actor, head] of Object.entries(state.frontier.heads)) {
    for (let seq = (inventory.heads[actor] || 0) + 1; seq <= head; seq += 1) {
      needed.add(`${actor}:${seq}`);
    }
  }
  for (const envelope of state.archiveEnvelopes.values()) {
    if (envelope.events.some((event) => needed.has(event.id))) {
      relay.send(client, 'mmo.world_events', {
        from: 'campaign-authority', envelope,
      });
    }
  }
  return true;
}

function publishAuthorityFrontier(relay, state) {
  if (state.pending && !state.pending.published) {
    const pendingClient = relay.clients.get(state.pending.clientId);
    if (pendingClient) pendingClient.worldSequencePending = null;
    state.requests.delete(worldRequestKey(state.pending.clientId, state.pending.request));
    state.pending = null;
  }
  for (const row of state.queue) {
    const queuedClient = relay.clients.get(row.clientId);
    if (queuedClient) queuedClient.worldSequencePending = null;
    state.requests.delete(worldRequestKey(row.clientId, row.request));
  }
  state.queue = [];
  for (const member of relay.clients.values()) {
    if (member.ready && sameWorld(member.worldState, state)) {
      member.worldAdmission = null;
      sendAuthorityFrontier(relay, member, state);
    }
  }
}

function worldRequestKey(clientId, request) { return `${clientId}|${request}`; }

function issueWorldGrant(relay, state) {
  if (state.pending) return false;
  while (state.queue.length) {
    const row = state.queue.shift();
    const client = relay.clients.get(row.clientId);
    const admitted = relay.protocol < 19 || (client && client.worldAdmission
      && sameGrantBase(row.base, client.worldAdmission.grantBase));
    if (client && client.ready && sameWorld(client.worldState, state) && admitted) {
      row.position = state.head + 1;
      row.grant = `world-grant-${randomBytes(16).toString('hex')}`;
      state.pending = row;
      const payload = {
        request: row.request, grant: row.grant,
        world: state.world, position: row.position,
      };
      if (relay.protocol >= 19) payload.base = row.base;
      relay.send(client, 'mmo.world_sequence_grant', payload);
      return true;
    }
    if (client && relay.protocol >= 19) client.worldSequencePending = null;
    state.requests.delete(worldRequestKey(row.clientId, row.request));
  }
  return false;
}

function releaseWorldRequests(relay, client) {
  for (const state of relay.worldTimelines.values()) {
    if (state.pending && state.pending.clientId === client.id) {
      // A relayed signed occupant survives its publisher. Another replica's
      // exact resulting frontier is the only safe way to release the slot.
      if (!(relay.protocol >= 19 && state.pending.published)) {
        state.requests.delete(worldRequestKey(client.id, state.pending.request));
        state.pending = null;
      }
    }
    state.queue = state.queue.filter((row) => {
      if (row.clientId !== client.id) return true;
      state.requests.delete(worldRequestKey(client.id, row.request));
      return false;
    });
    issueWorldGrant(relay, state);
  }
  client.worldSequencePending = null;
}

function pruneWorldTimelines(relay, excludingId = null) {
  if (relay.protocol >= 29) return;
  for (const [key, state] of relay.worldTimelines) {
    let occupied = false;
    for (const client of relay.clients.values()) {
      if (client.id !== excludingId && client.ready
          && sameWorld(client.worldState, state)) { occupied = true; break; }
    }
    if (!occupied && !state.pending && state.queue.length === 0) {
      relay.worldTimelines.delete(key);
    }
  }
}


handlers['mmo.world_archive_begin'] = (relay, client, msg) => {
  if (relay.protocol < 29 || !client.ready) return;
  if (relay.campaignArchiveCorrupt) {
    relay.send(client, 'mmo.world_unavailable', { reason: 'archive_corrupt' });
    return;
  }
  const begin = cleanWorldArchiveBegin(msg);
  if (!begin) return;
  const identity = { world: begin.inventory.world,
    compatibility: begin.inventory.compatibility,
    revision: begin.frontier.revision };
  if (relay.worldTimelines.has(`${identity.world}|${identity.compatibility}`)) {
    relay.send(client, 'mmo.world_archive_ready', identity);
    return;
  }
  client.worldArchiveUpload = { ...begin, envelopes: [], events: new Map() };
  relay.send(client, 'mmo.world_archive_needed', identity);
};

handlers['mmo.world_archive_batch'] = (relay, client, msg) => {
  if (relay.protocol < 29 || !client.ready || !client.worldArchiveUpload) return;
  const envelope = cleanWorldBatch(msg.envelope);
  const upload = client.worldArchiveUpload;
  if (!envelope || envelope.events.length !== 1
      || !sameWorld(envelope, upload.inventory)
      || upload.envelopes.length >= upload.batches) {
    client.worldArchiveUpload = null; return;
  }
  for (const event of envelope.events) {
    const previous = upload.events.get(event.id);
    if (previous && !isDeepStrictEqual(previous, event)) {
      client.worldArchiveUpload = null; return;
    }
    upload.events.set(event.id, event);
  }
  upload.envelopes.push(envelope);
};

handlers['mmo.world_archive_end'] = (relay, client, msg) => {
  if (relay.protocol < 29 || !client.ready || !client.worldArchiveUpload) return;
  const end = cleanWorldArchiveEnd(msg);
  const upload = client.worldArchiveUpload;
  client.worldArchiveUpload = null;
  if (!end || end.world !== upload.inventory.world
      || end.compatibility !== upload.inventory.compatibility
      || end.revision !== upload.frontier.revision
      || upload.envelopes.length !== upload.batches) return;
  const key = `${end.world}|${end.compatibility}`;
  let state = relay.worldTimelines.get(key);
  if (!state && !archiveCovers(upload.frontier, upload.events)) {
    relay.send(client, 'mmo.world_unavailable', { reason: 'archive_incomplete' });
    return;
  }
  if (!state) {
    state = makeWorldState(upload.inventory, upload.frontier);
    relay.worldTimelines.set(key, state);
  }
  for (const envelope of upload.envelopes) {
    if (!recordArchiveEnvelope(state, envelope)) {
      relay.send(client, 'mmo.world_unavailable', { reason: 'archive_conflict' });
      return;
    }
  }
  rebuildUncommittedEvidence(state);
  if (!notifyArchiveChange(relay)) {
    relay.worldTimelines.delete(key);
    relay.campaignArchiveCorrupt = true;
    relay.send(client, 'mmo.world_unavailable', { reason: 'archive_storage_failed' });
    return;
  }
  relay.send(client, 'mmo.world_archive_ready', end);
};

handlers['mmo.world_advertise'] = (relay, client, msg) => {
  if (!client.ready) return;
  const inventory = cleanWorldInventory(msg.inventory);
  const frontier = relay.protocol >= 19 ? cleanWorldFrontier(msg.frontier) : null;
  if (!inventory || (relay.protocol >= 19
      && (!frontier || !inventoryMatchesFrontier(inventory, frontier)))) return;
  for (const other of relay.clients.values()) {
    if (other.id !== client.id && other.ready && sameWorld(other.worldState, inventory)
        && other.worldState.player === inventory.player) {
      relay.send(client, 'mmo.world_unavailable', { reason: 'duplicate_player' });
      return;
    }
  }
  if (client.worldState && (!sameWorld(client.worldState, inventory)
      || client.worldState.player !== inventory.player)) {
    releaseWorldRequests(relay, client);
    pruneWorldTimelines(relay, client.id);
  }
  const previousAdmission = client.worldAdmission;
  client.worldState = inventory;
  client.worldFrontier = frontier;
  client.worldAdmission = null;
  const archiveKey = `${inventory.world}|${inventory.compatibility}`;
  const state = relay.protocol >= 29
    ? relay.worldTimelines.get(archiveKey)
    : worldTimeline(relay, inventory, frontier);
  if (!state) {
    relay.send(client, 'mmo.world_unavailable', { reason: 'archive_required' });
    return;
  }
  if (relay.protocol >= 19) {
    const pending = state.pending;
    const advancesPosition = Boolean(pending && pending.published
      && frontier.timelineHead === pending.position
      && frontier.timelineHead === state.head + 1);
    const advancesActorHeads = state.frontier
      && advancesOwnActorHead(state.frontier, frontier, inventory.player);
    const advancesRecovered = advancesFromRelayedEvidence(state, frontier,
      inventory.player);
    if (advancesPosition || advancesActorHeads || advancesRecovered) {
      const previousFrontier = state.frontier; const previousHead = state.head;
      state.frontier = frontier;
      state.head = frontier.timelineHead;
      if (relay.protocol >= 29 && !notifyArchiveChange(relay)) {
        state.frontier = previousFrontier; state.head = previousHead;
        relay.campaignArchiveCorrupt = true;
        relay.send(client, 'mmo.world_unavailable', {
          reason: 'archive_storage_failed',
        });
        return;
      }
      rebuildUncommittedEvidence(state);
      publishAuthorityFrontier(relay, state);
    } else if (previousAdmission && sameFrontier(frontier, state.frontier)
        && previousAdmission.authorityRevision === state.frontier.revision
        && previousAdmission.grantBase.position === state.head + 1
        && previousAdmission.grantBase.baseDigest === state.frontier.canonicalDigest) {
      client.worldAdmission = previousAdmission;
    } else if (relay.protocol >= 29 && replicaIsBehind(frontier, state.frontier)) {
      sendArchiveCatchup(relay, client, state, inventory);
      sendAuthorityFrontier(relay, client, state);
    } else if (relay.protocol >= 29 && !sameFrontier(frontier, state.frontier)) {
      relay.send(client, 'mmo.world_unavailable', { reason: 'archive_conflict' });
    } else {
      sendAuthorityFrontier(relay, client, state);
    }
  } else {
    relay.send(client, 'mmo.world_ready', {
      world: inventory.world, player: inventory.player,
    });
  }
  for (const other of relay.clients.values()) {
    if (other.ready && other.id !== client.id && sameWorld(other.worldState, inventory)) {
      relay.send(client, 'mmo.world_advertise', {
        from: other.id, inventory: other.worldState,
      });
      relay.send(other, 'mmo.world_advertise', { from: client.id, inventory });
    }
  }
};

handlers['mmo.world_frontier_ack'] = (relay, client, msg) => {
  if (relay.protocol < 19 || !client.ready || !client.worldState
      || !client.worldFrontier) return;
  const admission = cleanWorldFrontierAdmission(msg.admission);
  const state = worldTimeline(relay, client.worldState);
  if (!admission || !state.frontier
      || !sameFrontier(admission.frontier, client.worldFrontier)
      || admission.authorityRevision !== state.frontier.revision
      || admission.grantBase.world !== state.world
      || admission.grantBase.compatibility !== state.compatibility
      || admission.grantBase.position !== state.head + 1
      || admission.grantBase.baseDigest !== state.frontier.canonicalDigest
      || admission.grantBase.authorityRevision !== state.frontier.revision) return;
  client.worldAdmission = admission;
  relay.send(client, 'mmo.world_frontier_ready', { admission });
  const row = state.pending;
  if (row && row.published && state.head === row.position) {
    const writer = relay.clients.get(row.clientId);
    if (writer) writer.worldSequencePending = null;
    state.requests.delete(worldRequestKey(row.clientId, row.request));
    state.pending = null;
    issueWorldGrant(relay, state);
  }
};

handlers['mmo.world_events'] = (relay, client, msg) => {
  if (!client.ready) return;
  const envelope = cleanWorldBatch(msg.envelope);
  if (!envelope || !sameWorld(client.worldState, envelope)) return;
  const targetId = cleanId(msg.to);
  if (!targetId && envelope.events.some(
    (event) => event.actor !== client.worldState.player)) return;
  if (!targetId) {
    const state = worldTimeline(relay, client.worldState);
    const row = state.pending;
    let positioned = false;
    let matched = false;
    for (const event of envelope.events) {
      if (event.position !== undefined) {
        positioned = true;
        if (row && row.clientId === client.id && event.owner === 'world'
            && event.position === row.position && event.actor === row.actor
            && event.kind === row.kind && event.subject === row.subject) matched = true;
      }
    }
    if (positioned && !matched) return;
    if (matched) row.published = true;
  }
  if (targetId) {
    const target = relay.clients.get(targetId);
    if (target && target.ready && sameWorld(target.worldState, envelope)) {
      if (relay.protocol >= 19) {
        recordWorldEvidence(worldTimeline(relay, client.worldState), envelope.events);
      }
      relay.send(target, 'mmo.world_events', { from: client.id, envelope });
    }
    return;
  }
  if (relay.protocol >= 19) {
    const localState = worldTimeline(relay, client.worldState);
    recordWorldEvidence(localState, envelope.events);
    if (relay.protocol >= 29) {
      if (!recordArchiveEnvelope(localState, envelope)) return;
      if (!notifyArchiveChange(relay)) {
        relay.campaignArchiveCorrupt = true;
        relay.send(client, 'mmo.world_unavailable', {
          reason: 'archive_storage_failed',
        });
        return;
      }
    }
  }
  for (const target of relay.clients.values()) {
    if (target.id !== client.id && target.ready
        && sameWorld(target.worldState, envelope)) {
      relay.send(target, 'mmo.world_events', { from: client.id, envelope });
    }
  }
};

handlers['mmo.world_prefix'] = (relay, client, msg) => {
  if (relay.protocol < 23 || !client.ready || !client.worldState) return;
  const target = relay.clients.get(cleanId(msg.to));
  const packageValue = cleanWorldClosedPackage(msg.package);
  if (!target || !target.ready || !target.worldState
      || !packageValue
      || !sameWorld(client.worldState, target.worldState)
      || !sameWorld(client.worldState, packageValue)) return;
  relay.send(target, 'mmo.world_prefix', { from: client.id, package: packageValue });
};

handlers['mmo.world_prefix_frame'] = (relay, client, msg) => {
  if (relay.protocol < 24 || !client.ready || !client.worldState) return;
  const target = relay.clients.get(cleanId(msg.to));
  const frame = cleanWorldPrefixFrame(msg.frame);
  if (!target || !target.ready || !target.worldState || !frame
      || !sameWorld(client.worldState, target.worldState)
      || !sameWorld(client.worldState, frame)) return;
  relay.send(target, 'mmo.world_prefix_frame', { from: client.id, frame });
};

handlers['mmo.world_prefix_frame_ack'] = (relay, client, msg) => {
  if (relay.protocol < 24 || !client.ready || !client.worldState) return;
  const target = relay.clients.get(cleanId(msg.to));
  const acknowledgement = cleanWorldPrefixFrameAck(msg);
  if (!target || !target.ready || !target.worldState || !acknowledgement
      || !sameWorld(client.worldState, target.worldState)) return;
  relay.send(target, 'mmo.world_prefix_frame_ack', {
    from: client.id, transfer: acknowledgement.transfer,
    index: acknowledgement.index,
  });
};

handlers['mmo.world_invite'] = (relay, client, msg) => {
  if (!client.ready) return;
  const target = relay.clients.get(cleanId(msg.to));
  const invitation = cleanWorldInvitation(msg.invitation);
  if (!target || !target.ready || !invitation || !client.worldState
      || !sameWorld(client.worldState, invitation)
      || invitation.inviter !== client.worldState.player) return;
  relay.send(target, 'mmo.world_invite', {
    from: client.id, name: client.name, invitation,
  });
};

handlers['mmo.world_sequence_request'] = (relay, client, msg) => {
  if (!client.ready || !client.worldState) return;
  const request = cleanWorldSequenceRequest(msg);
  const base = relay.protocol >= 19 ? cleanWorldGrantBase(msg.base) : null;
  if (!request || request.actor !== client.worldState.player
      || client.worldSequencePending || (relay.protocol >= 19
        && (!base || !client.worldAdmission
          || !sameGrantBase(base, client.worldAdmission.grantBase)))) return;
  const state = worldTimeline(relay, client.worldState);
  const key = worldRequestKey(client.id, request.request);
  if (state.requests.has(key)) return;
  state.requests.add(key);
  client.worldSequencePending = key;
  state.queue.push({ clientId: client.id, ...request, base });
  issueWorldGrant(relay, state);
};

handlers['mmo.world_sequence_commit'] = (relay, client, msg) => {
  if (!client.ready || !client.worldState) return;
  const commit = cleanWorldSequenceGrant(msg);
  const state = worldTimeline(relay, client.worldState);
  const row = state.pending;
  if (!commit || !row || row.clientId !== client.id
      || row.request !== commit.request || row.grant !== commit.grant
      || row.position !== commit.position || commit.world !== state.world
      || commit.position !== state.head + 1 || row.published !== true) return;
  if (relay.protocol >= 19) {
    row.committed = true;
  } else {
    state.head = row.position;
    client.worldSequencePending = null;
    state.requests.delete(worldRequestKey(client.id, row.request));
    state.pending = null;
    issueWorldGrant(relay, state);
  }
};

handlers['mmo.world_sequence_cancel'] = (relay, client, msg) => {
  if (!client.ready || !client.worldState) return;
  const cancel = cleanWorldSequenceCancel(msg);
  const state = worldTimeline(relay, client.worldState);
  const row = state.pending;
  if (!cancel || !row || row.clientId !== client.id
      || row.request !== cancel.request || row.grant !== cancel.grant) return;
  // An unused reservation is cancellable; an already relayed signed occupant
  // remains held until a replica proves its exact resulting frontier.
  if (relay.protocol >= 19 && row.published) return;
  state.requests.delete(worldRequestKey(client.id, row.request));
  client.worldSequencePending = null;
  state.pending = null;
  issueWorldGrant(relay, state);
};


function initialize(relay, archive) {
  if (!(relay.worldTimelines instanceof Map)) relay.worldTimelines = new Map();
  if (relay.protocol >= 29) relay.campaignArchiveCorrupt = !importArchive(relay, archive);
}

module.exports = { handlers, initialize, exportArchive,
  releaseWorldRequests, pruneWorldTimelines };
