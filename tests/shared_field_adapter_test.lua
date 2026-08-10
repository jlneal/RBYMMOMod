-- Focused proof for the provider-neutral client adapter and ordinary NPC seam.
-- Run from this repository root: luajit tests/shared_field_adapter_test.lua

local loadstr = loadstring or load
local checks = 0
local function ok(value, label) assert(value, "FAIL: " .. label); checks = checks + 1 end
local function eq(actual, expected, label)
  assert(actual == expected, ("FAIL: %s (got %s, wanted %s)"):format(
    label, tostring(actual), tostring(expected))); checks = checks + 1
end

local sent, applied, granted, denied = {}, {}, {}, {}
local registered
local live = { map = "ROUTE_1", spawns = {{ id = "wild_1", species = "PIDGEY",
  level = 3, x = 5, y = 7, facing = "down", behavior = "GRASS_WANDER",
  surface = "GRASS", kind = "grass" }} }
local exports = {
  setSharedFieldProvider = function(provider) registered = provider; return true end,
  sharedFieldSnapshot = function(map)
    local out = { map = map, spawns = {} }
    for _, row in ipairs(live.spawns) do out.spawns[#out.spawns + 1] = row end
    return out
  end,
  sharedNeighborMaps = function() return { "ROUTE_2" } end,
  applySharedFieldSnapshot = function(snapshot) applied[#applied + 1] = snapshot end,
  grantSharedFieldContact = function(map, id)
    granted[#granted + 1] = map .. ":" .. id; return true
  end,
  denySharedFieldContact = function(map, id)
    denied[#denied + 1] = map .. ":" .. id; return true
  end,
  clearSharedField = function() registered = nil; return true end,
  resetSharedField = function() return true end,
}
local player = { cellX = 5, cellY = 7, facing = "up", surfing = false }
local testMod = { world = {
  current = function() return { mapId = "ROUTE_1", x = 5, y = 7 } end,
  overworld = function() return { player = player } end,
}, find = function(_, id)
  if id == "overworld_wild_spawns" then return { exports = exports } end
end }

local cache = {}
local function need(name)
  if cache[name] then return cache[name] end
  local handle = assert(io.open("src/" .. name .. ".lua", "rb"))
  local body = handle:read("*a"); handle:close()
  cache[name] = assert(loadstr(body, "@src/" .. name .. ".lua"))(need, testMod)
  return cache[name]
end
local Wire, SharedField = need("Wire"), need("SharedField")
local transport = { isReady = function() return true end,
  send = function(_, kind, payload) sent[#sent + 1] = { kind = kind, payload = payload } end }
local identity = { selfId = "ann" }
local roster = { sorted = function() return {
  { id = "bob", map = "ROUTE_1", x = 9, y = 7, facing = "left", busy = false },
  { id = "cal", map = "ROUTE_2", x = 1, y = 1, facing = "down", busy = false },
} end }
local bridge = SharedField.new(transport, identity, roster, {
  registerExport = "setSharedFieldProvider", resetExport = "resetSharedField",
  acceptContact = function(map, id, target)
    return map == "ROUTE_1" and id == "wild_1" and target == "ann"
  end,
})

bridge:update(0)
ok(registered ~= nil, "the transport adapter registers with the generic provider")
eq(sent[1].kind, Wire.FIELD_REQUEST, "entering a map requests its canonical field")
eq(sent[2].payload.map, "ROUTE_2", "resident neighbor maps are prewarmed")
local targets = registered:targets("ROUTE_1")
eq(#targets, 2, "authority sees local and unpartied remote trainers")
eq(targets[1].id, "ann", "target ordering is deterministic")
ok(registered:acceptContact("ROUTE_1", "wild_1", "ann"),
  "the local target may accept canonical contact")
ok(registered:claim("ROUTE_1", "wild_1"), "the provider can request an atomic claim")
eq(sent[#sent].kind, Wire.FIELD_CLAIM, "claim remains transport-owned")

bridge:onNeeded({ domain = "GROUND", map = "ROUTE_1", epoch = 0 })
eq(sent[#sent].kind, Wire.FIELD_SEED, "the authority seeds from provider state")
bridge:onSnapshot({ domain = "GROUND", map = "ROUTE_1", epoch = 0, revision = 1,
  authority = "bob", spawns = live.spawns })
eq(applied[#applied].localAuthority, false, "a replica does not run provider AI")
bridge:onSnapshot({ domain = "GROUND", map = "ROUTE_1", epoch = 0, revision = 1,
  spawns = live.spawns })
eq(applied[#applied].localAuthority, false,
  "an authority-less lease explicitly freezes the former authority")

bridge:onSnapshot({ domain = "GROUND", map = "ROUTE_1", epoch = 0, revision = 2,
  authority = "ann", spawns = live.spawns })
live.spawns[1].x = 6
bridge:update(0.6)
eq(sent[#sent].kind, Wire.FIELD_PUBLISH, "authority publishes provider movement")
local firstPublish = #sent
bridge:update(0.6)
eq(#sent, firstPublish + 1, "an unacknowledged CAS publish is retried")
bridge:onSnapshot({ domain = "GROUND", map = "ROUTE_1", epoch = 0, revision = 3,
  authority = "ann", spawns = live.spawns })
local acknowledged = #sent
bridge:update(0.6)
eq(#sent, acknowledged, "canonical echo stops publish retries")

ok(bridge:onGranted({ domain = "GROUND", map = "ROUTE_1", id = "wild_1" }),
  "a grant resolves the exact provider contact")
eq(granted[1], "ROUTE_1:wild_1", "grant keeps stable identity")
ok(bridge:onDenied({ domain = "GROUND", map = "ROUTE_1", id = "wild_2" }),
  "a denial releases provider pending state")
eq(denied[1], "ROUTE_1:wild_2", "denial keeps stable identity")
bridge:reset()
eq(registered, nil, "disconnect unregisters shared provider state")

local ambientApplied = {}
exports.sharedAmbientFieldSnapshot = function(map) return { map = map, spawns = {{
  id = "ambient_1", species = "RATTATA", x = 2, y = 3,
  facing = "left", behavior = "WANDER",
}} } end
exports.applySharedAmbientFieldSnapshot = function(snapshot)
  ambientApplied[#ambientApplied + 1] = snapshot; return true
end
exports.resetSharedAmbientField = function() return true end
exports.clearSharedAmbientField = function() return true end
exports.sharedAmbientNeighborMaps = function() return {} end
local ambient = SharedField.new(transport, identity, roster, {
  domain = "AMBIENT", snapshotExport = "sharedAmbientFieldSnapshot",
  applyExport = "applySharedAmbientFieldSnapshot",
  resetExport = "resetSharedAmbientField", clearExport = "clearSharedAmbientField",
  neighborExport = "sharedAmbientNeighborMaps",
})
ambient:onNeeded({ domain = "AMBIENT", map = "PALLET", epoch = 1, reset = true })
eq(sent[#sent].payload.domain, "AMBIENT", "ambient provider seeds its own namespace")
ambient:onSnapshot({ domain = "AMBIENT", map = "PALLET", epoch = 1, revision = 1,
  authority = "bob", spawns = exports.sharedAmbientFieldSnapshot("PALLET").spawns })
eq(#ambientApplied, 1, "ambient canonical state reaches the parallel provider export")
eq(ambientApplied[1].localAuthority, false, "ambient replicas remain presentation-only")

-- Ordinary NPC state is presentation only and excludes trainers/runtime NPCs.
local walker = { id = "ROUTE_1_obj_1", def = { movement = "WALK" },
  cellX = 5, cellY = 24, px = 80, py = 384, facing = "down", wanders = true }
local trainer = { id = "ROUTE_1_obj_2",
  def = { movement = "WALK", trainerClass = "OPP_YOUNGSTER" },
  cellX = 8, cellY = 8, wanders = true }
local runtime = { id = "ROUTE_1_obj_901",
  def = { movement = "WALK", runtime = true }, cellX = 7, cellY = 7, wanders = true }
local ow = { map = { id = "ROUTE_1" },
  npcPool = { [walker.id] = walker, [trainer.id] = trainer, [runtime.id] = runtime },
  scriptMoves = {}, neighbors = { { map = { id = "PALLET" } } },
  runner = { isRunning = function() return false end } }
testMod.world.overworld = function() return ow end
local NpcField = need("NpcField")
local npc = NpcField.new()
local snapshot = npc:snapshot("ROUTE_1")
eq(#snapshot.spawns, 1, "only ordinary native random walkers synchronize")
eq(snapshot.spawns[1].id, walker.id, "trainer progression remains local")
eq(npc:neighbors()[1], "PALLET", "ordinary walkers prewarm resident seams")
ok(npc:apply({ map = "ROUTE_1", localAuthority = false, spawns = {{
  id = walker.id, x = 6, y = 24, facing = "right", moving = true,
  targetX = 7, targetY = 24, progress = 4,
}}}), "replica applies canonical walker pose")
eq(walker.wanders, false, "replica cannot roll independent movement")
eq(walker.px, 100, "mid-step pixel pose is reconstructed")
ow.scriptMoves = { { entity = walker } }
walker.cellX = 12
npc:apply({ map = "ROUTE_1", localAuthority = false,
  spawns = {{ id = walker.id, x = 2, y = 2, moving = false, progress = 0 }} })
eq(walker.cellX, 12, "local scripted movement retains priority")
ok(npc:clear(), "disconnect releases NPC synchronization")
eq(walker.wanders, true, "native wandering resumes")

print(("\n  %d/%d checks passed  (shared field adapter)\n"):format(checks, checks))
