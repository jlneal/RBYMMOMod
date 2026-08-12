'use strict';

// Strict bounded envelopes for the optional campaign_state transport. These
// validate structure and resource limits only; MMO never interprets facts.

function cleanHex(value, maxLen) {
  if (typeof value !== 'string' || value.length > maxLen) return null;
  return /^[0-9a-f]+$/.test(value) ? value : null;
}

function cleanProgressionId(value, limit = 96) {
  if (typeof value !== 'string') return null;
  return new RegExp(`^[A-Za-z0-9_.:-]{1,${limit}}$`).test(value) ? value : null;
}

function cleanProgressionPayload(value, depth = 0, seen = new Set(), budget = { nodes: 0 }) {
  if (value === null) return undefined;
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return Number.isFinite(value) ? value : undefined;
  if (typeof value === 'string') return value.length <= 128 ? value : undefined;
  if (typeof value !== 'object' || Array.isArray(value) || depth >= 5
      || seen.has(value)) return undefined;
  seen.add(value);
  const keys = Object.keys(value);
  if (keys.length > 32) { seen.delete(value); return undefined; }
  const out = Object.create(null);
  for (const key of keys) {
    budget.nodes += 1;
    if (budget.nodes > 32) { seen.delete(value); return undefined; }
    if (!/^[A-Za-z0-9_.:-]{1,64}$/.test(key)) {
      seen.delete(value); return undefined;
    }
    const child = cleanProgressionPayload(value[key], depth + 1, seen, budget);
    if (child === undefined) { seen.delete(value); return undefined; }
    out[key] = child;
  }
  seen.delete(value);
  return out;
}

function cleanWorldEvent(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.schema !== 1) return null;
  const actor = cleanProgressionId(value.actor, 64);
  const world = cleanProgressionId(value.world, 64);
  const id = cleanProgressionId(value.id, 96);
  const kind = cleanProgressionId(value.kind, 64);
  const subject = cleanProgressionId(value.subject, 96);
  const seq = Number.isSafeInteger(value.seq) && value.seq >= 1 ? value.seq : null;
  const position = value.position == null ? null
    : (Number.isSafeInteger(value.position) && value.position >= 1
      ? value.position : null);
  const transaction = value.transaction == null ? null
    : cleanProgressionId(value.transaction, 96);
  const owner = value.owner === 'world' || value.owner === 'player'
    ? value.owner : null;
  const payload = cleanProgressionPayload(value.payload == null ? {} : value.payload);
  if (!actor || !world || !id || !kind || !subject || !seq || !owner
      || payload === undefined || id !== `${actor}:${seq}`
      || (value.position != null && position === null)
      || (position !== null && !transaction)
      || (position === null && value.transaction != null)) return null;
  const out = { schema: 1, id, world, actor, seq, owner, kind, subject, payload };
  if (position !== null) { out.position = position; out.transaction = transaction; }
  return out;
}

function cleanWorldInventory(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.schema !== 1) return null;
  const world = cleanProgressionId(value.world, 64);
  const compatibility = cleanProgressionId(value.compatibility, 96);
  const player = cleanProgressionId(value.player, 64);
  const tag = cleanHex(value.tag, 64);
  if (!world || !compatibility || !player || !tag || tag.length !== 64
      || !Number.isSafeInteger(value.timelineHead) || value.timelineHead < 0
      || !value.heads || typeof value.heads !== 'object'
      || Array.isArray(value.heads)) return null;
  const heads = Object.create(null);
  const actors = Object.keys(value.heads);
  if (actors.length > 64) return null;
  for (const rawActor of actors) {
    const actor = cleanProgressionId(rawActor, 64);
    const seq = value.heads[rawActor];
    if (!actor || !Number.isSafeInteger(seq) || seq < 0) return null;
    heads[actor] = seq;
  }
  return { schema: 1, world, compatibility, player,
    timelineHead: value.timelineHead, heads, tag };
}

function cleanWorldBatch(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.schema !== 1 || !Array.isArray(value.events)
      || value.events.length < 1 || value.events.length > 256) return null;
  const world = cleanProgressionId(value.world, 64);
  const compatibility = cleanProgressionId(value.compatibility, 96);
  const tag = cleanHex(value.tag, 64);
  if (!world || !compatibility || !tag || tag.length !== 64) return null;
  const events = [];
  for (const raw of value.events) {
    const event = cleanWorldEvent(raw);
    if (!event || event.world !== world) return null;
    events.push(event);
  }
  return { schema: 1, world, compatibility, events, tag };
}

function cleanWorldArchiveBegin(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const inventory = cleanWorldInventory(value.inventory);
  const frontier = cleanWorldFrontier(value.frontier);
  const batches = Number.isSafeInteger(value.batches) && value.batches >= 0
    && value.batches <= 4096 ? value.batches : null;
  if (!inventory || !frontier || batches === null
      || inventory.world !== frontier.world
      || inventory.compatibility !== frontier.compatibility
      || inventory.timelineHead !== frontier.timelineHead) return null;
  return { inventory, frontier, batches };
}

function cleanWorldArchiveEnd(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const world = cleanProgressionId(value.world, 64);
  const compatibility = cleanProgressionId(value.compatibility, 96);
  const revision = cleanHex(value.revision, 16);
  return world && compatibility && revision && revision.length === 16
    ? { world, compatibility, revision } : null;
}

function cleanCheckpointState(value, depth = 0, seen = new Set(), budget = { nodes: 0 }) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return Number.isFinite(value) ? value : undefined;
  if (typeof value === 'string') return value.length <= 128 ? value : undefined;
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || depth >= 8 || seen.has(value)) return undefined;
  seen.add(value);
  const out = Object.create(null);
  for (const key of Object.keys(value)) {
    budget.nodes += 1;
    if (budget.nodes > 16384 || !/^[A-Za-z0-9_.:-]{1,96}$/.test(key)) {
      seen.delete(value); return undefined;
    }
    const child = cleanCheckpointState(value[key], depth + 1, seen, budget);
    if (child === undefined) { seen.delete(value); return undefined; }
    out[key] = child;
  }
  seen.delete(value);
  return out;
}

function cleanWorldClosedBase(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.schema !== 1 || value.closed !== true) return null;
  const world = cleanProgressionId(value.world, 64);
  const compatibility = cleanProgressionId(value.compatibility, 96);
  const timelineHead = Number.isSafeInteger(value.timelineHead)
    && value.timelineHead >= 0 ? value.timelineHead : null;
  const events = Number.isSafeInteger(value.events) && value.events >= 0
    ? value.events : null;
  const canonicalDigest = cleanHex(value.canonicalDigest, 16);
  const stateDigest = cleanHex(value.stateDigest, 16);
  const checkpointRevision = cleanHex(value.checkpointRevision, 16);
  const closureDigest = cleanHex(value.closureDigest, 16);
  const tag = cleanHex(value.tag, 64);
  const state = cleanCheckpointState(value.state);
  if (!world || !compatibility || timelineHead === null || events === null
      || timelineHead > events || !canonicalDigest || canonicalDigest.length !== 16
      || !stateDigest || stateDigest.length !== 16 || !checkpointRevision
      || checkpointRevision.length !== 16 || !closureDigest
      || closureDigest.length !== 16 || !tag || tag.length !== 64
      || state === undefined || !value.heads || typeof value.heads !== 'object'
      || Array.isArray(value.heads)) return null;
  const heads = Object.create(null);
  const actors = Object.keys(value.heads);
  if (actors.length > 64) return null;
  let total = 0;
  for (const rawActor of actors) {
    const actor = cleanProgressionId(rawActor, 64);
    const seq = value.heads[rawActor];
    if (!actor || !Number.isSafeInteger(seq) || seq < 0) return null;
    heads[actor] = seq;
    total += seq;
    if (!Number.isSafeInteger(total)) return null;
  }
  if (total !== events) return null;
  return { schema: 1, world, compatibility, timelineHead, events,
    canonicalDigest, stateDigest, checkpointRevision, closureDigest,
    heads, state, closed: true, tag };
}

const MAX_CLOSED_PACKAGE_WIRE = 48 * 1024;
function conservativeWireSize(value, budget = { bytes: 0 }) {
  if (value === null || value === undefined) budget.bytes += 4;
  else if (typeof value === 'boolean') budget.bytes += 5;
  else if (typeof value === 'number') budget.bytes += 32;
  else if (typeof value === 'string') {
    const bytes = /^[A-Za-z0-9_.:-]*$/.test(value) ? value.length : value.length * 6;
    budget.bytes += bytes + 2;
  }
  else if (Array.isArray(value)) {
    budget.bytes += 2;
    for (const child of value) {
      if (!conservativeWireSize(child, budget)) return false;
    }
  } else if (value && typeof value === 'object') {
    budget.bytes += 2;
    for (const [key, child] of Object.entries(value)) {
      const bytes = /^[A-Za-z0-9_.:-]*$/.test(key) ? key.length : key.length * 6;
      budget.bytes += bytes + 3;
      if (!conservativeWireSize(child, budget)) return false;
    }
  } else return false;
  return budget.bytes <= MAX_CLOSED_PACKAGE_WIRE;
}

function cleanWorldClosedPackage(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.schema !== 1 || !Array.isArray(value.batches)
      || value.batches.length > 16) return null;
  const world = cleanProgressionId(value.world, 64);
  const compatibility = cleanProgressionId(value.compatibility, 96);
  const base = cleanWorldClosedBase(value.base);
  const frontier = cleanWorldFrontier(value.frontier);
  if (!world || !compatibility || !base || !frontier
      || base.world !== world || base.compatibility !== compatibility
      || frontier.world !== world || frontier.compatibility !== compatibility) return null;
  const batches = [];
  for (const raw of value.batches) {
    const batch = cleanWorldBatch(raw);
    if (!batch || batch.world !== world || batch.compatibility !== compatibility) return null;
    batches.push(batch);
  }
  const clean = { schema: 1, world, compatibility, base, batches, frontier };
  return conservativeWireSize(clean) ? clean : null;
}

function cleanFrameValue(value, depth = 0, budget = { nodes: 0 }) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return Number.isFinite(value) ? value : undefined;
  if (typeof value === 'string') return value.length <= 128 ? value : undefined;
  if (!value || typeof value !== 'object' || depth >= 12) return undefined;
  if (Array.isArray(value)) {
    const out = [];
    for (const child of value) {
      budget.nodes += 1;
      if (budget.nodes > 1024) return undefined;
      const clean = cleanFrameValue(child, depth + 1, budget);
      if (clean === undefined) return undefined;
      out.push(clean);
    }
    return out;
  }
  const out = Object.create(null);
  for (const [key, child] of Object.entries(value)) {
    budget.nodes += 1;
    if (budget.nodes > 1024 || !cleanProgressionId(key, 96)) return undefined;
    const clean = cleanFrameValue(child, depth + 1, budget);
    if (clean === undefined) return undefined;
    out[key] = clean;
  }
  return out;
}

function cleanWorldPrefixFrame(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.schema !== 1) return null;
  const world = cleanProgressionId(value.world, 64);
  const compatibility = cleanProgressionId(value.compatibility, 96);
  const transfer = cleanHex(value.transfer, 32);
  const index = Number.isSafeInteger(value.index) && value.index >= 1
    && value.index <= 24576 ? value.index : null;
  const total = Number.isSafeInteger(value.total) && value.total >= 1
    && value.total <= 24576 ? value.total : null;
  const payload = cleanFrameValue(value.payload);
  if (!world || !compatibility || !transfer || transfer.length !== 32
      || index === null || total === null || index > total || payload === undefined) return null;
  const clean = { schema: 1, world, compatibility, transfer, index, total };
  if (value.kind === 'manifest') {
    if (!payload.base || typeof payload.base !== 'object' || Array.isArray(payload.base)
        || payload.base.state !== undefined || !payload.frontier
        || typeof payload.frontier !== 'object' || Array.isArray(payload.frontier)
        || !Number.isSafeInteger(payload.states) || payload.states < 1
        || payload.states > 24576 || !Number.isSafeInteger(payload.batches)
        || payload.batches < 0 || payload.batches > 24576) return null;
    clean.kind = 'manifest'; clean.payload = payload;
  } else if (value.kind === 'state') {
    if (!Array.isArray(payload.path) || payload.path.length > 8
        || !payload.path.every((part) => cleanProgressionId(part, 96))) return null;
    const empty = payload.empty === true;
    const hasValue = payload.value !== undefined;
    if (empty === hasValue || (hasValue && typeof payload.value === 'object')) return null;
    clean.kind = 'state'; clean.payload = payload;
  } else if (value.kind === 'batch') {
    const ordinal = Number.isSafeInteger(value.ordinal) && value.ordinal >= 1
      && value.ordinal <= 24576 ? value.ordinal : null;
    const batch = cleanWorldBatch(payload);
    if (ordinal === null || !batch) return null;
    clean.kind = 'batch'; clean.ordinal = ordinal; clean.payload = batch;
  } else return null;
  return conservativeWireSize(clean) ? clean : null;
}

function cleanWorldPrefixFrameAck(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const transfer = cleanHex(value.transfer, 32);
  const index = Number.isSafeInteger(value.index) && value.index >= 1
    && value.index <= 24576 ? value.index : null;
  return transfer && transfer.length === 32 && index !== null ? { transfer, index } : null;
}

function cleanWorldInvitation(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.schema !== 1) return null;
  const world = cleanProgressionId(value.world, 64);
  const compatibility = cleanProgressionId(value.compatibility, 96);
  const inviter = cleanProgressionId(value.inviter, 64);
  const worldKey = cleanProgressionId(value.worldKey, 96);
  const tag = cleanHex(value.tag, 64);
  if (!world || !compatibility || !inviter || !worldKey
      || !tag || tag.length !== 64) return null;
  return { schema: 1, world, compatibility, inviter, worldKey, tag };
}

function cleanWorldSequenceRequest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const request = cleanProgressionId(value.request, 64);
  const actor = cleanProgressionId(value.actor, 64);
  const kind = cleanProgressionId(value.kind, 64);
  const subject = cleanProgressionId(value.subject, 96);
  return request && actor && kind && subject ? { request, actor, kind, subject } : null;
}

function cleanWorldSequenceGrant(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const request = cleanProgressionId(value.request, 64);
  const grant = cleanProgressionId(value.grant, 96);
  const world = cleanProgressionId(value.world, 64);
  const position = Number.isSafeInteger(value.position) && value.position >= 1
    ? value.position : null;
  return request && grant && world && position
    ? { request, grant, world, position } : null;
}

function cleanWorldSequenceCancel(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const request = cleanProgressionId(value.request, 64);
  const grant = cleanProgressionId(value.grant, 96);
  return request && grant ? { request, grant } : null;
}

// Protocol-19 campaign admission vocabulary. Protocol 18 does not route these
// yet; both hub implementations land and prove the same strict shapes first.
function cleanWorldFrontier(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.version !== 1) return null;
  const world = cleanProgressionId(value.world, 64);
  const compatibility = cleanProgressionId(value.compatibility, 96);
  const timelineHead = Number.isSafeInteger(value.timelineHead)
    && value.timelineHead >= 0
    ? value.timelineHead : null;
  const canonicalDigest = cleanHex(value.canonicalDigest, 16);
  const revision = cleanHex(value.revision, 16);
  const tag = cleanHex(value.tag, 64);
  if (!world || !compatibility || timelineHead === null
      || !canonicalDigest || canonicalDigest.length !== 16
      || !revision || revision.length !== 16 || !tag || tag.length !== 64
      || !value.heads || typeof value.heads !== 'object'
      || Array.isArray(value.heads)) return null;
  const heads = Object.create(null);
  const actors = Object.keys(value.heads);
  if (actors.length > 64) return null;
  for (const rawActor of actors) {
    const actor = cleanProgressionId(rawActor, 64);
    const seq = value.heads[rawActor];
    if (!actor || !Number.isSafeInteger(seq) || seq < 0) return null;
    heads[actor] = seq;
  }
  return { version: 1, world, compatibility, timelineHead,
    canonicalDigest, heads, revision, tag };
}

function cleanWorldGrantBase(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.version !== 1) return null;
  const world = cleanProgressionId(value.world, 64);
  const compatibility = cleanProgressionId(value.compatibility, 96);
  const position = Number.isSafeInteger(value.position)
    && value.position >= 1 ? value.position : null;
  const baseDigest = cleanHex(value.baseDigest, 16);
  const authorityRevision = cleanHex(value.authorityRevision, 16);
  const replicaRevision = cleanHex(value.replicaRevision, 16);
  if (!world || !compatibility || position === null || !baseDigest
      || baseDigest.length !== 16 || !authorityRevision
      || authorityRevision.length !== 16 || !replicaRevision
      || replicaRevision.length !== 16) return null;
  return { version: 1, world, compatibility, position, baseDigest,
    authorityRevision, replicaRevision };
}

function cleanWorldFrontierAdmission(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const frontier = cleanWorldFrontier(value.frontier);
  const grantBase = cleanWorldGrantBase(value.grantBase);
  const authorityRevision = cleanHex(value.authorityRevision, 16);
  const replicaRevision = cleanHex(value.replicaRevision, 16);
  if (!frontier || !grantBase || !authorityRevision
      || authorityRevision.length !== 16 || !replicaRevision
      || replicaRevision.length !== 16
      || authorityRevision !== grantBase.authorityRevision
      || replicaRevision !== grantBase.replicaRevision
      || replicaRevision !== frontier.revision
      || frontier.world !== grantBase.world
      || frontier.compatibility !== grantBase.compatibility
      || grantBase.position !== frontier.timelineHead + 1) return null;
  return { frontier, authorityRevision, replicaRevision, grantBase };
}

module.exports = {
  cleanProgressionId,
  cleanWorldInventory, cleanWorldBatch, cleanWorldInvitation,
  cleanWorldArchiveBegin, cleanWorldArchiveEnd,
  cleanWorldClosedBase, cleanWorldClosedPackage,
  cleanWorldPrefixFrame, cleanWorldPrefixFrameAck,
  cleanWorldSequenceRequest, cleanWorldSequenceGrant,
  cleanWorldSequenceCancel, cleanWorldFrontier, cleanWorldGrantBase,
  cleanWorldFrontierAdmission,
};
