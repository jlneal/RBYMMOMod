local root, cache = "src/", {}
local function need(name)
  if cache[name] then return cache[name] end
  local chunk = assert(loadfile(root .. name .. ".lua"))
  local value = chunk(need, {})
  cache[name] = value
  return value
end
local Hub, Wire, CampaignWire = need("Hub"), need("Wire"), need("CampaignWire")
local passed = 0
local function check(value, message) assert(value, message); passed = passed + 1 end
local function eq(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": expected "
    .. tostring(expected) .. ", got " .. tostring(actual)); passed = passed + 1
end
local function peer()
  local value = { outbox = {} }
  function value:send(message) self.outbox[#self.outbox + 1] = message end
  function value:close() self.closed = true end
  return value
end
local function take(remote, kind)
  for index, message in ipairs(remote.outbox) do
    if message.type == kind then return table.remove(remote.outbox, index) end
  end
end
local serial = 0
local function join(hub, name)
  serial = serial + 1
  local remote, client = peer()
  client = assert(hub:accept(remote))
  hub:receive(client, { type = Wire.HELLO, proto = 29, name = name,
    playerId = ("%032x"):format(serial), map = "PALLET", x = 1, y = 1,
    facing = "down" })
  assert(take(remote, Wire.WELCOME))
  return client, remote
end

local world, compatibility = "durable-world", "campaign-state.4.durable"
local tag = string.rep("a", 64)
local event = { schema = 1, id = "ann:1", world = world, actor = "ann", seq = 1,
  position = 1, transaction = "durable-transaction-one", owner = "world",
  kind = "pokemon.unique.resolve", subject = "articuno",
  payload = { outcome = "captured" } }
local envelope = { schema = 1, world = world, compatibility = compatibility,
  events = { event }, tag = tag }
local heads1 = { ann = 1 }
local frontier1 = { version = 1, world = world, compatibility = compatibility,
  timelineHead = 1, canonicalDigest = string.rep("b", 16), heads = heads1,
  revision = string.rep("c", 16), tag = tag }
local inventory1 = { schema = 1, world = world, compatibility = compatibility,
  player = "ann", timelineHead = 1, heads = heads1, tag = tag }
local persisted
local hub = Hub.new({ maxPlayers = 2, protocol = 29,
  onCampaignChange = function(value) persisted = value end })
local ann, annPeer = join(hub, "ANN")
hub:receive(ann, { type = CampaignWire.ARCHIVE_BEGIN, inventory = inventory1,
  frontier = frontier1, batches = 1 })
check(persisted and #persisted.worlds == 0,
  "authority identity is durable before bootstrap is accepted")
hub:receive(ann, { type = CampaignWire.ARCHIVE_BATCH, envelope = envelope })
hub:receive(ann, { type = CampaignWire.ARCHIVE_END, world = world,
  compatibility = compatibility, revision = frontier1.revision })
eq(take(annPeer, CampaignWire.ARCHIVE_READY).revision, frontier1.revision,
  "embedded authority adopts a complete authenticated archive")
check(persisted and persisted.worlds[1], "embedded authority emits durable storage")
check(type(persisted.authority) == "string",
  "embedded authority persists a stable server identity")
hub:drop(ann)
check(next(hub.worldTimelines) ~= nil, "vacancy does not erase embedded canon")

local restarted = Hub.new({ maxPlayers = 2, protocol = 29 })
check(restarted:importCampaignArchive(persisted), "fresh embedded hub loads durable canon")
local stale, stalePeer = join(restarted, "STALE")
local heads0 = { ann = 0 }
local frontier0 = { version = 1, world = world, compatibility = compatibility,
  timelineHead = 0, canonicalDigest = string.rep("d", 16), heads = heads0,
  revision = string.rep("e", 16), tag = tag }
local inventory0 = { schema = 1, world = world, compatibility = compatibility,
  player = "bob", timelineHead = 0, heads = heads0, tag = tag }
restarted:receive(stale, { type = CampaignWire.ARCHIVE_BEGIN,
  inventory = inventory0, frontier = frontier0, batches = 0 })
restarted:receive(stale, { type = CampaignWire.ARCHIVE_END, world = world,
  compatibility = compatibility, revision = frontier0.revision })
check(take(stalePeer, CampaignWire.ARCHIVE_READY),
  "existing server archive acknowledges a stale replica without adopting it")
restarted:receive(stale, { type = CampaignWire.ADVERTISE,
  inventory = inventory0, frontier = frontier0 })
eq(take(stalePeer, CampaignWire.EVENTS).from, "campaign-authority",
  "stale replica hydrates from the server rather than another participant")
eq(take(stalePeer, CampaignWire.FRONTIER).frontier.revision, frontier1.revision,
  "server retains the exact canonical frontier across restart")

local unrelated = Hub.new({ maxPlayers = 1, protocol = 29 })
local misplaced, misplacedPeer = join(unrelated, "MISPLACED")
unrelated:receive(misplaced, { type = CampaignWire.ARCHIVE_BEGIN,
  inventory = inventory1, frontier = frontier1, batches = 1,
  authority = persisted.authority })
eq(take(misplacedPeer, CampaignWire.UNAVAILABLE).reason, "wrong_authority",
  "a save bound to one server cannot bootstrap a second canonical server")

local broken = Hub.new({ maxPlayers = 2, protocol = 29 })
eq(broken:importCampaignArchive({ schema = 0 }), false,
  "corrupt durable archive fails closed")
local refused, refusedPeer = join(broken, "REFUSED")
broken:receive(refused, { type = CampaignWire.ARCHIVE_BEGIN,
  inventory = inventory0, frontier = frontier0, batches = 0 })
eq(take(refusedPeer, CampaignWire.UNAVAILABLE).reason, "archive_corrupt",
  "participant save cannot silently replace corrupt server storage")

print(("durable campaign embedded hub: %d assertions passed"):format(passed))
