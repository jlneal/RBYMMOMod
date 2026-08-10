-- Focused display-only remote convoy proof.
-- Run: luajit tests/remote_convoy_test.lua

local loadstr = loadstring or load
local checks = 0
local function ok(value, label) assert(value, "FAIL: " .. label); checks = checks + 1 end
local function eq(actual, expected, label)
  assert(actual == expected, ("FAIL: %s (got %s, wanted %s)"):format(
    label, tostring(actual), tostring(expected))); checks = checks + 1
end

local spawned, removed = {}, {}
local wilds = {
  spawnRemoteFollower = function(_, row)
    local npc = { cellX = row.x, cellY = row.y, px = row.x * 16, py = row.y * 16,
      facing = row.facing, moving = false, mmoRemoteFollower = true }
    spawned[#spawned + 1] = npc
    return npc
  end,
  removeRemoteFollower = function(_, npc) removed[#removed + 1] = npc; return true end,
}
local testMod = {
  id = "rby_mmo", world = { game = {}, overworld = function() return nil end },
  find = function(_, id)
    if id == "overworld_wild_spawns" then return { exports = wilds } end
  end,
  content = { sprites = {} }, log = { warn = function() end },
}
local cache = {}
local function need(name)
  if cache[name] then return cache[name] end
  local handle = assert(io.open("src/" .. name .. ".lua", "rb"))
  local body = handle:read("*a"); handle:close()
  cache[name] = assert(loadstr(body, "@src/" .. name .. ".lua"))(need, testMod)
  return cache[name]
end

local Wire, Avatars = need("Wire"), need("Avatars")
local Client = need("Client")
local destination = Client.presencePosition(
  { mapId = "ROUTE_1", x = 4, y = 5, facing = "right" },
  { cellX = 4, cellY = 5, targetX = 5, targetY = 5, moving = true })
eq(destination.x, 5,
  "moving presence uses the same landing-cell clock as its convoy")
eq(Client.presencePosition({ mapId = "ROUTE_1", x = 4, y = 5 },
  { cellX = 4, cellY = 5, moving = false }).x, 4,
  "standing presence retains the occupied cell")
local raw = {}
for i = 1, 8 do raw[i] = { species = "MON_" .. i, map = "ROUTE_1",
  x = i, y = 5, facing = "right", hp = 99, moves = { "TACKLE" } } end
raw[2].species = "bad value"
local clean = Wire.convoy(raw)
eq(#clean, 6, "convoy is bounded after malformed rows are dropped")
eq(clean[1].species, "MON_1", "display species survives")
eq(clean[1].hp, nil, "HP never enters presence")
eq(clean[1].moves, nil, "moves never enter presence")
eq(Wire.presence({ id = "p", name = "ANN", convoy = raw }).convoy[1].species,
  "MON_1", "presence re-sanitizes the complete convoy")

local Hub, Config = need("Hub"), need("Config")
local peer = { messages = {}, send = function(self, message)
  self.messages[#self.messages + 1] = message
end, close = function() end }
local hub = Hub.new({ maxPlayers = 2 })
local client = assert(hub:accept(peer))
hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "ANN",
  map = "ROUTE_1", x = 1, y = 1,
  convoy = { { species = "PIKACHU", x = 0, y = 1, hp = 20 } } })
eq(client.convoy[1].species, "PIKACHU", "embedded hub accepts sanitized convoy")
eq(client.convoy[1].hp, nil, "embedded hub never stores private HP")
hub:receive(client, { type = Wire.MOVE, map = "ROUTE_1", x = 2, y = 1,
  convoy = { { species = "EEVEE", x = 1, y = 1, nickname = "PRIVATE" } } })
eq(client.convoy[1].species, "EEVEE", "embedded hub replaces convoy on move")
eq(client.convoy[1].nickname, nil, "embedded hub never stores private nicknames")

local projected = Avatars.projectPlayer({ id = "p", map = "ROUTE_1", x = 2, y = 2,
  convoy = {
    { species = "PIKACHU", map = "ROUTE_1", x = 1, y = 2 },
    { species = "EEVEE", map = "VIRIDIAN_CITY", x = 8, y = 9 },
  },
}, "VIRIDIAN_CITY", { { map = { id = "ROUTE_1" }, ox = 160, oy = -576 } })
eq(projected.convoy[1].x, 11, "neighbor follower receives the seam translation")
eq(projected.convoy[2].x, 8, "straddling follower keeps its active-map cell")

local avatars, av = Avatars.new(), { followers = {} }
avatars:syncFollowers(av, { convoy = {
  { species = "PIKACHU", x = 4, y = 5, facing = "right" },
  { species = "EEVEE", x = 3, y = 5, facing = "right" },
} })
eq(#spawned, 2, "Wilds constructs each remote presentation")
eq(#av.followers, 2, "the avatar owns the resulting display train")
avatars:syncFollowers(av, { convoy = {
  { species = "RAICHU", x = 4, y = 5, facing = "right" },
} })
eq(#removed, 2, "a composition change removes the previous train")
eq(#av.followers, 1, "and atomically replaces it")
avatars:syncFollowers(av, { airborne = true, convoy = {
  { species = "RAICHU", x = 4, y = 5 }, { species = "PIDGEOT", x = 3, y = 5 },
} })
eq(#av.followers, 0, "takeoff hides the complete ground convoy")
avatars:syncFollowers(av, { airborne = false, convoy = {
  { species = "RAICHU", x = 4, y = 5 }, { species = "PIDGEOT", x = 3, y = 5 },
} })
eq(#av.followers, 2, "landing rebuilds the complete latest snapshot at once")

local moving = { npc = { cellX = 4, cellY = 5, moving = true } }
avatars:advanceFollower(moving, { species = "PIKACHU", x = 6, y = 5, hop = true })
ok(moving.pendingHop, "a hop arriving mid-step is retained")
moving.npc.moving = false
avatars:advanceFollower(moving, { species = "PIKACHU", x = 6, y = 5, hop = false })
eq(moving.npc.hopStep, true, "the retained two-cell step remains a hop")
eq(moving.npc.targetX, 6, "the retained hop targets its landing cell")

print(("\n  %d/%d checks passed  (remote convoy)\n"):format(checks, checks))
