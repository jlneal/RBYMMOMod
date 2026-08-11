local root, cache = "src/", {}
local function need(name)
  if cache[name] then return cache[name] end
  local chunk, why = loadfile(root .. name .. ".lua")
  assert(chunk, why)
  cache[name] = chunk(need, {})
  return cache[name]
end

local Hub = need("Hub")
local Wire = need("Wire")
local CampaignWire = need("CampaignWire")
local Bridge = need("CampaignStateBridge")
local passed = 0
local function check(value, message) assert(value, message); passed = passed + 1 end
local function eq(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": expected "
    .. tostring(expected) .. ", got " .. tostring(actual))
  passed = passed + 1
end

local hub = Hub.new({ maxPlayers = 2, protocol = 19 })
local bridge, attached, delivered
local peer = { outbox = {} }
function peer:close() self.closed = true end
function peer:send(message)
  self.outbox[#self.outbox + 1] = message
  if not bridge then return end
  if message.type == CampaignWire.FRONTIER then
    bridge:onFrontier(assert(CampaignWire.worldFrontier(message.frontier)))
  elseif message.type == CampaignWire.FRONTIER_READY then
    bridge:onFrontierReady(assert(CampaignWire.worldFrontierAdmission(message.admission)))
  elseif message.type == CampaignWire.SEQUENCE_GRANT then
    bridge:onGrant(assert(CampaignWire.worldSequenceGrant(message, true)))
  elseif message.type == CampaignWire.UNAVAILABLE then
    bridge:onUnavailable(assert(CampaignWire.worldUnavailable(message)).reason)
  end
end

local client = assert(hub:accept(peer))
hub:receive(client, { type = Wire.HELLO, proto = 19, name = "ANN",
  playerId = string.rep("a", 32), map = "PALLET", x = 1, y = 1,
  facing = "down" })
check(client.ready, "protocol-19 client joins the embedded hub")

local tag = string.rep("a", 64)
local digest0, revision0 = string.rep("b", 16), string.rep("c", 16)
local digest1, revision1 = string.rep("d", 16), string.rep("e", 16)
local head, digest, revision, actorHead = 0, digest0, revision0, 0
local function frontier()
  return { version = 1, world = "integration-world",
    compatibility = "campaign-state.4.integration", timelineHead = head,
    canonicalDigest = digest, heads = { ann = actorHead },
    revision = revision, tag = tag }
end
local function inventory()
  return { schema = 1, world = "integration-world",
    compatibility = "campaign-state.4.integration", player = "ann",
    timelineHead = head, heads = { ann = actorHead }, tag = tag }
end
local function grantBase()
  return { version = 1, world = "integration-world",
    compatibility = "campaign-state.4.integration", position = head + 1,
    baseDigest = digest, authorityRevision = revision,
    replicaRevision = revision }
end

local api = {
  status = function() return { active = true,
    worldId = "integration-world", playerId = "ann" } end,
  inventory = inventory,
  frontier = frontier,
  admission = function(authority, acknowledged)
    if acknowledged == nil then
      return { state = "matched", replica = { revision = revision } }
    end
    if acknowledged ~= revision then return nil, "stale acknowledgement" end
    return { state = "writable", grantBase = grantBase() }
  end,
  validateGrantBase = function(candidate)
    local expected = grantBase()
    return candidate.world == expected.world
      and candidate.compatibility == expected.compatibility
      and candidate.position == expected.position
      and candidate.baseDigest == expected.baseDigest
      and candidate.authorityRevision == expected.authorityRevision
      and candidate.replicaRevision == expected.replicaRevision
      or nil, "grant base changed"
  end,
  batch = function(events)
    return { schema = 1, world = "integration-world",
      compatibility = "campaign-state.4.integration", events = events,
      tag = tag }
  end,
  missing = function() return {} end,
  receive = function() return 0 end,
}

local foundation = { apiVersion = 3 }
function foundation.registerTransport(id, transport)
  eq(id, "rby-mmo", "bridge registers under its stable transport id")
  attached = transport
  transport.attach(api)
  return true
end
function foundation.invitation() return nil, "campaign is inactive" end
function foundation.acceptInvitation() return true end

bridge = assert(Bridge.new({ foundation = foundation,
  frontierAdmission = true,
  connected = function() return true end,
  send = function(kind, payload)
    local message = { type = kind }
    for key, value in pairs(payload or {}) do message[key] = value end
    hub:receive(client, message)
  end,
}))
check(bridge:install(), "bridge installs against the real hub transport")
check(bridge:advertise(), "signed inventory starts frontier admission")
eq(bridge.admission:status().state, "writable",
  "exact embedded-hub echo makes the replica writable")

check(attached.authority:request("ann", "pokemon.unique.resolve", "articuno",
  function(grant) delivered = grant end) == "pending",
  "campaign reservation is submitted asynchronously")
check(delivered and delivered.position == 1,
  "the real hub's next canonical position reaches Campaign State")

local event = { schema = 1, id = "ann:1", world = "integration-world",
  actor = "ann", seq = 1, position = 1, transaction = "transaction-one",
  owner = "world", kind = "pokemon.unique.resolve", subject = "articuno",
  payload = { outcome = "captured" } }
eq(attached.authority:commit(delivered.grant, { event }), 1,
  "signed occupant publishes and commits at its granted position")
local _, pendingState = next(hub.worldTimelines)
check(pendingState.pending ~= nil,
  "commit alone cannot release a published canonical position")

head, actorHead, digest, revision = 1, 1, digest1, revision1
check(bridge:advertise(), "resulting signed frontier is advertised")
local _, state = next(hub.worldTimelines)
eq(state.head, 1, "hub advances only after the resulting frontier")
eq(state.pending, nil, "exact frontier acknowledgement releases the position")
eq(bridge.admission:status().state, "writable",
  "replica is re-admitted on the new canonical base")

print(("campaign protocol integration: %d assertions passed"):format(passed))
