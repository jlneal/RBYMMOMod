-- Bounded wire vocabulary for the optional campaign_state adapter.
-- Campaign facts remain opaque to MMO; this module validates only envelope
-- shape and resource limits before either hub routes them.

local need = ...
local Wire = need("Wire")
local CampaignIdentity = need("CampaignIdentity")

local M = {}
M.MAX_CLOSED_PACKAGE_WIRE = 48 * 1024

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
M.PREFIX = "mmo.world_prefix"
M.PREFIX_FRAME = "mmo.world_prefix_frame"
M.PREFIX_FRAME_ACK = "mmo.world_prefix_frame_ack"
M.ARCHIVE_BEGIN = "mmo.world_archive_begin"
M.ARCHIVE_BATCH = "mmo.world_archive_batch"
M.ARCHIVE_END = "mmo.world_archive_end"
M.ARCHIVE_NEEDED = "mmo.world_archive_needed"
M.ARCHIVE_READY = "mmo.world_archive_ready"

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

function M.worldArchiveBegin(raw)
  if type(raw) ~= "table" then return nil end
  local inventory = M.worldInventory(raw.inventory)
  local frontier = M.worldFrontier and M.worldFrontier(raw.frontier) or nil
  local batches = Wire.int(raw.batches, 0, 16384)
  if not (inventory and frontier and batches
    and inventory.world == frontier.world
    and inventory.compatibility == frontier.compatibility
    and inventory.timelineHead == frontier.timelineHead) then return nil end
  return { inventory = inventory, frontier = frontier, batches = batches }
end

function M.worldArchiveEnd(raw)
  if type(raw) ~= "table" then return nil end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local compatibility = CampaignIdentity.identifier(raw.compatibility, 96)
  local revision = Wire.hex(raw.revision, 16)
  return world and compatibility and revision and #revision == 16
    and { world = world, compatibility = compatibility, revision = revision }
    or nil
end

local function checkpointState(value, depth, seen, budget)
  local kind = type(value)
  if value == nil or kind == "boolean" then return value end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
  end
  if kind == "string" then return #value <= 128 and value or nil end
  if kind ~= "table" or (depth or 0) >= 8 then return nil end
  seen, budget = seen or {}, budget or { nodes = 0 }
  if seen[value] then return nil end
  seen[value] = true
  local out = {}
  for key, child in pairs(value) do
    budget.nodes = budget.nodes + 1
    if budget.nodes > 16384 or not CampaignIdentity.identifier(key, 96) then
      seen[value] = nil; return nil
    end
    local clean = checkpointState(child, (depth or 0) + 1, seen, budget)
    if clean == nil and child ~= nil then seen[value] = nil; return nil end
    out[key] = clean
  end
  seen[value] = nil
  return out
end

function M.worldClosedBase(raw)
  if type(raw) ~= "table" or raw.schema ~= 1 or raw.closed ~= true then return nil end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local compatibility = CampaignIdentity.identifier(raw.compatibility, 96)
  local timelineHead = Wire.int(raw.timelineHead, 0, 9007199254740991)
  local events = Wire.int(raw.events, 0, 9007199254740991)
  local canonicalDigest = Wire.hex(raw.canonicalDigest, 16)
  local stateDigest = Wire.hex(raw.stateDigest, 16)
  local checkpointRevision = Wire.hex(raw.checkpointRevision, 16)
  local closureDigest = Wire.hex(raw.closureDigest, 16)
  local tag = Wire.hex(raw.tag, 64)
  local state = checkpointState(raw.state)
  if not (world and compatibility and timelineHead and events
    and timelineHead <= events and canonicalDigest and #canonicalDigest == 16
    and stateDigest and #stateDigest == 16 and checkpointRevision
    and #checkpointRevision == 16 and closureDigest and #closureDigest == 16
    and tag and #tag == 64 and state and type(raw.heads) == "table") then return nil end
  local heads, actors, total = {}, 0, 0
  for rawActor, rawSeq in pairs(raw.heads) do
    local actor = CampaignIdentity.identifier(rawActor, 64)
    local seq = Wire.int(rawSeq, 0, 9007199254740991)
    actors = actors + 1
    if not (actor and seq) or actors > 64 then return nil end
    heads[actor], total = seq, total + seq
  end
  if total ~= events then return nil end
  return { schema = 1, world = world, compatibility = compatibility,
    timelineHead = timelineHead, events = events,
    canonicalDigest = canonicalDigest, stateDigest = stateDigest,
    checkpointRevision = checkpointRevision, closureDigest = closureDigest,
    heads = heads, state = state, closed = true, tag = tag }
end

local function conservativeWireSize(value, budget)
  local kind = type(value)
  if value == nil then budget.bytes = budget.bytes + 4
  elseif kind == "boolean" then budget.bytes = budget.bytes + 5
  elseif kind == "number" then budget.bytes = budget.bytes + 32
  elseif kind == "string" then
    local bytes = value:match("^[A-Za-z0-9_.:%-]*$") and #value or (#value * 6)
    budget.bytes = budget.bytes + bytes + 2
  elseif kind == "table" then
    budget.bytes = budget.bytes + 2
    for key, child in pairs(value) do
      if type(key) == "string" then
        local bytes = key:match("^[A-Za-z0-9_.:%-]*$") and #key or (#key * 6)
        budget.bytes = budget.bytes + bytes + 3
      else budget.bytes = budget.bytes + 16 end
      conservativeWireSize(child, budget)
      if budget.bytes > M.MAX_CLOSED_PACKAGE_WIRE then return false end
    end
  else return false end
  return budget.bytes <= M.MAX_CLOSED_PACKAGE_WIRE
end

local function frameValue(value, depth, seen, budget)
  local kind = type(value)
  if value == nil or kind == "boolean" then return value end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
  end
  if kind == "string" then return #value <= 128 and value or nil end
  if kind ~= "table" or (depth or 0) >= 12 then return nil end
  seen, budget = seen or {}, budget or { nodes = 0 }
  if seen[value] then return nil end
  seen[value] = true
  local out, numeric, textual, count, highest = {}, false, false, 0, 0
  for key, child in pairs(value) do
    count, budget.nodes = count + 1, budget.nodes + 1
    if budget.nodes > 1024 then seen[value] = nil; return nil end
    if type(key) == "number" then
      numeric = true
      if key < 1 or key ~= math.floor(key) then seen[value] = nil; return nil end
      highest = math.max(highest, key)
    elseif type(key) == "string" and CampaignIdentity.identifier(key, 96) then
      textual = true
    else seen[value] = nil; return nil end
    if numeric and textual then seen[value] = nil; return nil end
    local clean = frameValue(child, (depth or 0) + 1, seen, budget)
    if clean == nil and child ~= nil then seen[value] = nil; return nil end
    out[key] = clean
  end
  if numeric and count ~= highest then seen[value] = nil; return nil end
  seen[value] = nil
  return out
end

function M.worldPrefixFrame(raw)
  if type(raw) ~= "table" or raw.schema ~= 1 then return nil end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local compatibility = CampaignIdentity.identifier(raw.compatibility, 96)
  local transfer = Wire.hex(raw.transfer, 32)
  local index = Wire.int(raw.index, 1, 24576)
  local total = Wire.int(raw.total, 1, 24576)
  local payload = frameValue(raw.payload)
  if not (world and compatibility and transfer and #transfer == 32
    and index and total and index <= total and payload) then return nil end
  local clean = { schema = 1, world = world, compatibility = compatibility,
    transfer = transfer, index = index, total = total }
  if raw.kind == "manifest" then
    if type(payload.base) ~= "table" or payload.base.state ~= nil
      or type(payload.frontier) ~= "table"
      or not Wire.int(payload.states, 1, 24576)
      or not Wire.int(payload.batches, 0, 24576) then return nil end
    clean.kind, clean.payload = "manifest", payload
  elseif raw.kind == "state" then
    if type(payload.path) ~= "table" or #payload.path > 8 then return nil end
    for _, part in ipairs(payload.path) do
      if not CampaignIdentity.identifier(part, 96) then return nil end
    end
    local empty, hasValue = payload.empty == true, payload.value ~= nil
    if empty == hasValue or (hasValue and type(payload.value) == "table") then return nil end
    clean.kind, clean.payload = "state", payload
  elseif raw.kind == "batch" then
    local ordinal = Wire.int(raw.ordinal, 1, 24576)
    local batch = M.worldBatch(payload)
    if not ordinal or not batch then return nil end
    clean.kind, clean.ordinal, clean.payload = "batch", ordinal, batch
  else return nil end
  return conservativeWireSize(clean, { bytes = 0 }) and clean or nil
end

function M.worldPrefixFrameAck(raw)
  if type(raw) ~= "table" then return nil end
  local transfer = Wire.hex(raw.transfer, 32)
  local index = Wire.int(raw.index, 1, 24576)
  return transfer and #transfer == 32 and index
    and { transfer = transfer, index = index } or nil
end

function M.worldClosedPackage(raw)
  if type(raw) ~= "table" or raw.schema ~= 1 then return nil end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local compatibility = CampaignIdentity.identifier(raw.compatibility, 96)
  local base = M.worldClosedBase(raw.base)
  local frontier = M.worldFrontier and M.worldFrontier(raw.frontier) or nil
  if not (world and compatibility and base and frontier
    and base.world == world and base.compatibility == compatibility
    and frontier.world == world and frontier.compatibility == compatibility
    and type(raw.batches) == "table") then return nil end
  local count, highest = 0, 0
  for key in pairs(raw.batches) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
    count, highest = count + 1, math.max(highest, key)
    if count > 16 then return nil end
  end
  if count ~= highest then return nil end
  local batches = {}
  for index, value in ipairs(raw.batches) do
    local batch = M.worldBatch(value)
    if not batch or batch.world ~= world
      or batch.compatibility ~= compatibility then return nil end
    batches[index] = batch
  end
  local clean = { schema = 1, world = world, compatibility = compatibility,
    base = base, batches = batches, frontier = frontier }
  return conservativeWireSize(clean, { bytes = 0 }) and clean or nil
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
  local allowed = { duplicate_player = true, invalid_world = true,
    archive_required = true, archive_incomplete = true, archive_conflict = true }
  allowed.archive_corrupt = true
  allowed.archive_storage_failed = true
  local reason = allowed[raw.reason] and raw.reason or nil
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
  local timelineHead = worldInteger(raw.timelineHead, 0, 9007199254740991)
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
  local position = worldInteger(raw.position, 1, 9007199254740991)
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
