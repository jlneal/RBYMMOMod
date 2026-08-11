'use strict';

const { randomBytes } = require('node:crypto');
const { cleanId } = require('./sanitize');
const {
  cleanWorldInventory, cleanWorldBatch, cleanWorldInvitation,
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

function worldTimeline(relay, inventory, frontier = null) {
  const key = `${inventory.world}|${inventory.compatibility}`;
  let state = relay.worldTimelines.get(key);
  if (!state) {
    state = { key, world: inventory.world, compatibility: inventory.compatibility,
      head: inventory.timelineHead,
      frontier: relay.protocol >= 19 ? frontier : null,
      evidenceIds: new Map(), evidenceActors: new Map(),
      evidencePositions: new Set(), evidenceCount: 0,
      pending: null, queue: [], requests: new Set() };
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
  const state = worldTimeline(relay, inventory, frontier);
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
      state.frontier = frontier;
      state.head = frontier.timelineHead;
      pruneWorldEvidence(state);
      publishAuthorityFrontier(relay, state);
    } else if (previousAdmission && sameFrontier(frontier, state.frontier)
        && previousAdmission.authorityRevision === state.frontier.revision
        && previousAdmission.grantBase.position === state.head + 1
        && previousAdmission.grantBase.baseDigest === state.frontier.canonicalDigest) {
      client.worldAdmission = previousAdmission;
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
    recordWorldEvidence(worldTimeline(relay, client.worldState), envelope.events);
  }
  for (const target of relay.clients.values()) {
    if (target.id !== client.id && target.ready
        && sameWorld(target.worldState, envelope)) {
      relay.send(target, 'mmo.world_events', { from: client.id, envelope });
    }
  }
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


function initialize(relay) {
  if (!(relay.worldTimelines instanceof Map)) relay.worldTimelines = new Map();
}

module.exports = { handlers, initialize, releaseWorldRequests, pruneWorldTimelines };

