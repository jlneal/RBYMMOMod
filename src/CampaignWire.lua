-- Bounded wire vocabulary for the optional campaign_state adapter.
-- Campaign facts remain opaque to MMO; this module validates only envelope
-- shape and resource limits before either hub routes them.

local need = ...
local Wire = need("Wire")
local CampaignIdentity = need("CampaignIdentity")

local M = {}

M.ADVERTISE = "mmo.world_advertise"
M.EVENTS = "mmo.world_events"
M.INVITE = "mmo.world_invite"
M.SEQUENCE_REQUEST = "mmo.world_sequence_request"
M.SEQUENCE_GRANT = "mmo.world_sequence_grant"
M.SEQUENCE_COMMIT = "mmo.world_sequence_commit"
M.SEQUENCE_CANCEL = "mmo.world_sequence_cancel"
M.READY = "mmo.world_ready"
M.UNAVAILABLE = "mmo.world_unavailable"
M.FRONTIER = "mmo.world_frontier"
M.FRONTIER_ACK = "mmo.world_frontier_ack"
M.FRONTIER_READY = "mmo.world_frontier_ready"

local function worldPayload(value, depth, seen, budget)
  local kind = type(value)
  if value == nil or kind == "boolean" then return value end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
  end
  if kind == "string" then return #value <= 128 and value or nil end
  if kind ~= "table" or (depth or 0) >= 5 then return nil end
  seen, budget = seen or {}, budget or { nodes = 0 }
  if seen[value] then return nil end
  seen[value] = true
  local out, count = {}, 0
  for key, child in pairs(value) do
    count, budget.nodes = count + 1, budget.nodes + 1
    if count > 32 or budget.nodes > 32
      or not CampaignIdentity.identifier(key, 64) then seen[value] = nil; return nil end
    local clean = worldPayload(child, (depth or 0) + 1, seen, budget)
    if clean == nil and child ~= nil then seen[value] = nil; return nil end
    out[key] = clean
  end
  seen[value] = nil
  return out
end

function M.worldEvent(raw)
  if type(raw) ~= "table" or raw.schema ~= 1 then return nil end
  local actor = CampaignIdentity.identifier(raw.actor, 64)
  local world = CampaignIdentity.identifier(raw.world, 64)
  local id = CampaignIdentity.identifier(raw.id, 96)
  local kind = CampaignIdentity.identifier(raw.kind, 64)
  local subject = CampaignIdentity.identifier(raw.subject, 96)
  local seq = Wire.int(raw.seq, 1, 9007199254740991)
  local position = raw.position == nil and nil
    or Wire.int(raw.position, 1, 9007199254740991)
  local transaction = raw.transaction == nil and nil
    or CampaignIdentity.identifier(raw.transaction, 96)
  local owner = raw.owner == "world" and "world"
    or (raw.owner == "player" and "player" or nil)
  local payload = worldPayload(raw.payload or {})
  if not (actor and world and id and kind and subject and seq and owner and payload)
    or id ~= actor .. ":" .. tostring(seq)
    or (raw.position ~= nil and not position)
    or (position and not transaction)
    or (not position and raw.transaction ~= nil) then return nil end
  local out = { schema = 1, id = id, world = world, actor = actor, seq = seq,
    owner = owner, kind = kind, subject = subject, payload = payload }
  if position then out.position, out.transaction = position, transaction end
  return out
end

function M.worldInventory(raw)
  if type(raw) ~= "table" or raw.schema ~= 1 then return nil end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local compatibility = CampaignIdentity.identifier(raw.compatibility, 96)
  local player = CampaignIdentity.identifier(raw.player, 64)
  local timelineHead = Wire.int(raw.timelineHead, 0, 9007199254740991)
  local tag = Wire.hex(raw.tag, 64)
  if not (world and compatibility and player and timelineHead and tag
    and #tag == 64 and type(raw.heads) == "table") then return nil end
  local heads, count = {}, 0
  for rawActor, rawSeq in pairs(raw.heads) do
    local actor = CampaignIdentity.identifier(rawActor, 64)
    local seq = Wire.int(rawSeq, 0, 9007199254740991)
    count = count + 1
    if not (actor and seq) or count > 64 then return nil end
    heads[actor] = seq
  end
  return { schema = 1, world = world, compatibility = compatibility,
    player = player, timelineHead = timelineHead, heads = heads, tag = tag }
end

function M.worldBatch(raw)
  if type(raw) ~= "table" or raw.schema ~= 1 or type(raw.events) ~= "table" then
    return nil
  end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local compatibility = CampaignIdentity.identifier(raw.compatibility, 96)
  local tag = Wire.hex(raw.tag, 64)
  if not (world and compatibility and tag and #tag == 64) then return nil end
  local count, highest = 0, 0
  for key in pairs(raw.events) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
    count, highest = count + 1, math.max(highest, key)
  end
  if count ~= highest or count < 1 or count > 256 then return nil end
  local events = {}
  for index, rawEvent in ipairs(raw.events) do
    local event = M.worldEvent(rawEvent)
    if not event or event.world ~= world then return nil end
    events[index] = event
  end
  return { schema = 1, world = world, compatibility = compatibility,
    events = events, tag = tag }
end

function M.worldInvitation(raw)
  if type(raw) ~= "table" or raw.schema ~= 1 then return nil end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local compatibility = CampaignIdentity.identifier(raw.compatibility, 96)
  local inviter = CampaignIdentity.identifier(raw.inviter, 64)
  local worldKey = CampaignIdentity.identifier(raw.worldKey, 96)
  local tag = Wire.hex(raw.tag, 64)
  if not (world and compatibility and inviter and worldKey and tag and #tag == 64) then
    return nil
  end
  return { schema = 1, world = world, compatibility = compatibility,
    inviter = inviter, worldKey = worldKey, tag = tag }
end

function M.worldSequenceRequest(raw)
  if type(raw) ~= "table" then return nil end
  local request = CampaignIdentity.identifier(raw.request, 64)
  local actor = CampaignIdentity.identifier(raw.actor, 64)
  local kind = CampaignIdentity.identifier(raw.kind, 64)
  local subject = CampaignIdentity.identifier(raw.subject, 96)
  if not (request and actor and kind and subject) then return nil end
  return { request = request, actor = actor, kind = kind, subject = subject }
end

function M.worldSequenceGrant(raw, requireBase)
  if type(raw) ~= "table" then return nil end
  local request = CampaignIdentity.identifier(raw.request, 64)
  local grant = CampaignIdentity.identifier(raw.grant, 96)
  local world = CampaignIdentity.identifier(raw.world, 64)
  local position = Wire.int(raw.position, 1, 9007199254740991)
  local base = requireBase and M.worldGrantBase(raw.base) or nil
  if not (request and grant and world and position)
    or (requireBase and not base) then return nil end
  local out = { request = request, grant = grant, world = world, position = position }
  if base then out.base = base end
  return out
end

function M.worldSequenceCommit(raw)
  local grant = M.worldSequenceGrant(raw)
  if not grant then return nil end
  return grant
end

function M.worldSequenceCancel(raw)
  if type(raw) ~= "table" then return nil end
  local request = CampaignIdentity.identifier(raw.request, 64)
  local grant = CampaignIdentity.identifier(raw.grant, 96)
  if not (request and grant) then return nil end
  return { request = request, grant = grant }
end

function M.worldReady(raw)
  if type(raw) ~= "table" then return nil end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local player = CampaignIdentity.identifier(raw.player, 64)
  if not (world and player) then return nil end
  return { world = world, player = player }
end

function M.worldUnavailable(raw)
  if type(raw) ~= "table" then return nil end
  local reason = raw.reason == "duplicate_player" and "duplicate_player"
    or (raw.reason == "invalid_world" and "invalid_world" or nil)
  return reason and { reason = reason } or nil
end

-- Protocol-19 campaign admission artifacts. These sanitizers are deliberately
-- unused by protocol 18; landing the common bounded vocabulary first lets the
-- embedded and dedicated hubs prove identical refusal behavior before any
-- live sequence request depends on it.
local function worldInteger(value, minimum, maximum)
  return type(value) == "number" and value == math.floor(value)
    and value >= minimum and value <= maximum and value or nil
end

function M.worldFrontier(raw)
  if type(raw) ~= "table" or raw.version ~= 1 then return nil end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local compatibility = CampaignIdentity.identifier(raw.compatibility, 96)
  local timelineHead = worldInteger(raw.timelineHead, 0, 4096)
  local canonicalDigest = Wire.hex(raw.canonicalDigest, 16)
  local revision = Wire.hex(raw.revision, 16)
  local tag = Wire.hex(raw.tag, 64)
  if not (world and compatibility and timelineHead and canonicalDigest
    and #canonicalDigest == 16 and revision and #revision == 16
    and tag and #tag == 64 and type(raw.heads) == "table") then return nil end
  local heads, count = {}, 0
  for rawActor, rawSeq in pairs(raw.heads) do
    local actor = CampaignIdentity.identifier(rawActor, 64)
    local seq = worldInteger(rawSeq, 0, 9007199254740991)
    count = count + 1
    if not (actor and seq) or count > 64 then return nil end
    heads[actor] = seq
  end
  return { version = 1, world = world, compatibility = compatibility,
    timelineHead = timelineHead, canonicalDigest = canonicalDigest,
    heads = heads, revision = revision, tag = tag }
end

function M.worldGrantBase(raw)
  if type(raw) ~= "table" or raw.version ~= 1 then return nil end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local compatibility = CampaignIdentity.identifier(raw.compatibility, 96)
  local position = worldInteger(raw.position, 1, 4097)
  local baseDigest = Wire.hex(raw.baseDigest, 16)
  local authorityRevision = Wire.hex(raw.authorityRevision, 16)
  local replicaRevision = Wire.hex(raw.replicaRevision, 16)
  if not (world and compatibility and position and baseDigest
    and #baseDigest == 16 and authorityRevision and #authorityRevision == 16
    and replicaRevision and #replicaRevision == 16) then return nil end
  return { version = 1, world = world, compatibility = compatibility,
    position = position, baseDigest = baseDigest,
    authorityRevision = authorityRevision, replicaRevision = replicaRevision }
end

function M.worldFrontierAdmission(raw)
  if type(raw) ~= "table" then return nil end
  local frontier = M.worldFrontier(raw.frontier)
  local grantBase = M.worldGrantBase(raw.grantBase)
  local authorityRevision = Wire.hex(raw.authorityRevision, 16)
  local replicaRevision = Wire.hex(raw.replicaRevision, 16)
  if not (frontier and grantBase and authorityRevision
    and #authorityRevision == 16 and replicaRevision and #replicaRevision == 16
    and authorityRevision == grantBase.authorityRevision
    and replicaRevision == grantBase.replicaRevision
    and replicaRevision == frontier.revision
    and frontier.world == grantBase.world
    and frontier.compatibility == grantBase.compatibility
    and grantBase.position == frontier.timelineHead + 1) then return nil end
  return { frontier = frontier, authorityRevision = authorityRevision,
    replicaRevision = replicaRevision, grantBase = grantBase }
end

return M
