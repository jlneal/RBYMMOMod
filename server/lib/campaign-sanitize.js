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
    && value.timelineHead >= 0 && value.timelineHead <= 4096
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
    && value.position >= 1 && value.position <= 4097 ? value.position : null;
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
  cleanWorldInventory, cleanWorldBatch, cleanWorldInvitation,
  cleanWorldSequenceRequest, cleanWorldSequenceGrant,
  cleanWorldSequenceCancel, cleanWorldFrontier, cleanWorldGrantBase,
  cleanWorldFrontierAdmission,
};
