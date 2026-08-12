-- Focused, engine-independent proof for the shared-field protocol core.
-- Run from this repository root: luajit tests/shared_field_protocol_test.lua

local loadstr = loadstring or load
local cache = {}
local function need(name)
  if cache[name] then return cache[name] end
  local handle = assert(io.open("src/" .. name .. ".lua", "rb"))
  local body = handle:read("*a"); handle:close()
  local chunk = assert(loadstr(body, "@src/" .. name .. ".lua"))
  cache[name] = chunk(need)
  return cache[name]
end

local Wire, Hub, Config = need("Wire"), need("Hub"), need("Config")
local checks = 0
local function ok(value, label)
  assert(value, "FAIL: " .. label); checks = checks + 1
end
local function eq(actual, expected, label)
  assert(actual == expected, ("FAIL: %s (got %s, wanted %s)"):format(
    label, tostring(actual), tostring(expected))); checks = checks + 1
end

local function ground(map)
  return { domain = "GROUND", map = map or "ROUTE_1", epoch = 0, revision = 0,
    spawns = {{ id = "ground_1", species = "PIDGEY", level = 3, x = 4, y = 5,
      facing = "left", behavior = "GRASS_WANDER", surface = "GRASS", kind = "grass" }} }
end

ok(Wire.fieldSnapshot(ground()), "GROUND sanitizes")
ok(Wire.fieldSnapshot({ domain = "AMBIENT", map = "PALLET", revision = 0,
  spawns = {{ id = "ambient_1", species = "RATTATA", x = 2, y = 3,
    behavior = "WANDER" }} }), "AMBIENT sanitizes without a battle level")
ok(Wire.fieldSnapshot({ domain = "SKY", map = "PALLET", revision = 0,
  spawns = {{ id = "sky_1", species = "PIDGEOT", level = 36, x = 200, y = 100,
    alt = 64, mode = "roam", vx = 2, vy = -1 }} }), "SKY sanitizes")
ok(Wire.fieldSnapshot({ domain = "NPC", map = "PALLET", revision = 0,
  spawns = {{ id = "npc_1", x = 3, y = 4, moving = true,
    targetX = 4, targetY = 4, progress = 2 }} }), "NPC sanitizes")

local sparse = ground(); sparse.spawns[3] = sparse.spawns[1]; sparse.spawns[1] = nil
eq(Wire.fieldSnapshot(sparse), nil, "sparse populations are rejected")
local invalid = ground(); invalid.domain = "UNKNOWN"
eq(Wire.fieldSnapshot(invalid), nil, "unknown domains are rejected")

local function peer()
  return { messages = {}, send = function(self, message)
    self.messages[#self.messages + 1] = message
  end, close = function() end }
end
local hub = Hub.new({ maxPlayers = 4 })
local function connect(name, map)
  local wire = peer()
  local client = assert(hub:accept(wire))
  hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
    name = name, playerId = string.rep(name:sub(1, 1):lower(), 32),
    map = map, x = 1, y = 1 })
  wire.messages = {}
  return client, wire
end
local ann, annWire = connect("ANN", "ROUTE_1")
local bob, bobWire = connect("BOB", "ROUTE_1")
local seed = ground(); seed.type = Wire.FIELD_SEED
hub:receive(ann, seed)
eq(hub.wildFields["GROUND:ROUTE_1"].revision, 1, "the authority seeds revision one")
eq(bobWire.messages[#bobWire.messages].authority, ann.id, "authority is deterministic")

annWire.messages = {}
hub:receive(ann, { type = Wire.FIELD_CLAIM, domain = "GROUND",
  map = "ROUTE_1", id = "ground_1" })
eq(annWire.messages[#annWire.messages - 1].type, Wire.FIELD_GRANTED,
  "grant precedes the removal snapshot")
eq(#hub.wildFields["GROUND:ROUTE_1"].spawns, 0, "claim removes exactly one stable id")
hub:receive(bob, { type = Wire.FIELD_CLAIM, domain = "GROUND",
  map = "ROUTE_1", id = "ground_1" })
eq(bobWire.messages[#bobWire.messages].type, Wire.FIELD_DENIED,
  "a second claim loses atomically")

print(("\n  %d/%d checks passed  (shared field protocol)\n"):format(checks, checks))
