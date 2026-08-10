-- Focused remote-avatar seam, battle, ghost, and interaction proof.
-- Run: luajit tests/presence_lifecycle_test.lua

local loadstr = loadstring or load
local checks = 0
local function ok(value, label) assert(value, "FAIL: " .. label); checks = checks + 1 end
local function eq(actual, expected, label)
  assert(actual == expected, ("FAIL: %s (got %s, wanted %s)"):format(
    label, tostring(actual), tostring(expected))); checks = checks + 1
end

local overworld = { npcs = {}, entities = {}, ghosts = {}, neighbors = {} }
local testMod = {
  id = "rby_mmo",
  world = {
    overworld = function() return overworld end,
    removeNpc = function() return true end,
    npc = function() return nil end,
  },
  content = { sprites = {} },
  log = { warn = function() end },
}

local cache = {}
local function need(name)
  if cache[name] then return cache[name] end
  local handle = assert(io.open("src/" .. name .. ".lua", "rb"))
  local body = handle:read("*a"); handle:close()
  cache[name] = assert(loadstr(body, "@src/" .. name .. ".lua"))(need, testMod)
  return cache[name]
end

local Avatars = need("Avatars")

local original = { id = "bob", map = "ROUTE_1", x = 10, y = 2,
  facing = "right" }
local projected = Avatars.projectPlayer(original, "VIRIDIAN_CITY", {
  { map = { id = "ROUTE_1" }, ox = 160, oy = -576 },
})
eq(projected.map, "VIRIDIAN_CITY", "neighbor presence enters the active frame")
eq(projected.x, 20, "neighbor x is translated by the renderer offset")
eq(projected.y, -34, "neighbor y is translated by the renderer offset")
eq(original.map, "ROUTE_1", "projection does not mutate network truth")
eq(Avatars.projectPlayer(original, "PEWTER_CITY", {}), nil,
  "a player outside the streamed neighborhood stays hidden")

local avatars = Avatars.new()
local coopState = {}
ok(avatars:canProject({ stack = { states = { { kind = "menu" } } } }, coopState),
  "ordinary screens leave remote projection active")
eq(avatars:canProject({ stack = { states = { { kind = "trainer" } } } }, coopState),
  false, "trainer battles suppress the frozen overworld")
eq(avatars:canProject({ stack = { states = { { kind = "wild" } } } }, coopState),
  false, "wild battles suppress the frozen overworld")
eq(avatars:canProject({ stack = { states = { coopState } } }, coopState), false,
  "the MMO battle screen suppresses the frozen overworld")

local live = { id = "mmo_live", mmoAvatar = true }
local stale = { id = "mmo_stale", def = {
  runtime = true, owner = "rby_mmo", name = "mmo_bob",
} }
local authored = { id = "nurse", def = { name = "nurse" } }
avatars.spawned.bob = { npcId = "mmo_live", npc = live }
overworld = {
  npcs = { authored, stale, live },
  entities = { authored, stale, live },
  ghosts = {
    { npc = stale, peers = { authored, stale, live } },
    { npc = authored, peers = { authored, stale, live } },
  },
}
ok(avatars:purgeRestoredVisuals(overworld) > 0,
  "a restored battle snapshot reports stale identities removed")
eq(#overworld.npcs, 2, "the stale avatar leaves the NPC list")
eq(#overworld.entities, 2, "the stale avatar leaves the draw list")
eq(#overworld.ghosts, 1, "the stale avatar leaves the ghost list")
eq(#overworld.ghosts[1].peers, 2, "the stale avatar leaves ghost peer lists")
eq(overworld.npcs[1], authored, "authored NPCs are never classified as MMO debris")

overworld.npcs, overworld.entities = {}, {}
avatars:reattachCurrentVisuals(overworld)
eq(overworld.npcs[1], live, "the current avatar is reattached for interactions")
eq(overworld.entities[1], live, "the current avatar is reattached for drawing")
avatars:reattachCurrentVisuals(overworld)
eq(#overworld.entities, 1, "reattachment is idempotent")

local follower = { id = "follower", pokepcTrailer = true }
local remote = { id = "remote", mmoAvatar = true }
local story = { id = "story" }
overworld.npcs = { follower, remote, story }
ok(Avatars.prioritizeInteractions(overworld),
  "an overlapped interaction list is repaired once")
eq(overworld.npcs[1], story, "authored NPC interaction precedence is retained")
eq(overworld.npcs[2], remote, "remote players take precedence over followers")
eq(overworld.npcs[3], follower, "followers are the final interaction fallback")
eq(Avatars.prioritizeInteractions(overworld), false,
  "interaction ordering is stable on later ticks")

overworld.ghosts = {
  { npc = { id = "mmo_live" }, peers = { { id = "mmo_live" }, authored } },
  { npc = authored, peers = { authored, { id = "mmo_live" } } },
}
ok(avatars:despawn("bob"), "PART removes the tracked avatar")
eq(#overworld.ghosts, 1, "despawn purges its stale neighbor ghost")
eq(#overworld.ghosts[1].peers, 1, "despawn purges its stale peer references")

print(("\n  %d/%d checks passed  (presence lifecycle)\n"):format(checks, checks))
