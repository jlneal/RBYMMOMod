-- Focused airborne presence, SKY eligibility, adapter, and presentation proof.
-- Run: luajit tests/flight_sky_test.lua

local loadstr = loadstring or load
local checks = 0
local function ok(value, label) assert(value, "FAIL: " .. label); checks = checks + 1 end
local function eq(actual, expected, label)
  assert(actual == expected, ("FAIL: %s (got %s, wanted %s)"):format(
    label, tostring(actual), tostring(expected))); checks = checks + 1
end

local skyProvider, unregistered, skyApplied
local skyExports = {
  registerSharedSkyProvider = function(id, provider)
    eq(id, "rby_mmo", "SKY provider registers by stable companion id")
    skyProvider = provider; return true
  end,
  unregisterSharedSkyProvider = function(id) unregistered = id; return true end,
  sharedSkyNeighborMaps = function() return { "ROUTE_2" } end,
  sharedSkyFieldSnapshot = function(map) return { map = map, spawns = {{
    id = "sky_1", species = "PIDGEOT", level = 36, x = 160, y = 96,
    alt = 56, facing = "right", mode = "roam", vx = 2, vy = 0,
  }} } end,
  applySharedSkyFieldSnapshot = function(snapshot) skyApplied = snapshot; return true end,
  grantSharedSkyFieldContact = function() return true end,
  denySharedSkyFieldContact = function() return true end,
  clearSharedSkyField = function() return true end,
}
local wildsExports = { resolveFollowerSprite = function() return { id = "bird" } end }
local testMod = { id = "rby_mmo", world = {
  current = function() return { mapId = "ROUTE_1", x = 5, y = 5 } end,
  overworld = function() return { player = { cellX = 5, cellY = 5 }, entities = {} } end,
}, find = function(_, id)
  if id == "wild_skies" then return { exports = skyExports } end
  if id == "overworld_wild_spawns" then return { exports = wildsExports } end
end, content = { sprites = { get = function() return true end } },
  log = { warn = function() end } }

local cache = {}
local function need(name)
  if cache[name] then return cache[name] end
  local handle = assert(io.open("src/" .. name .. ".lua", "rb"))
  local body = handle:read("*a"); handle:close()
  cache[name] = assert(loadstr(body, "@src/" .. name .. ".lua"))(need, testMod)
  return cache[name]
end
local Config, Wire, Hub = need("Config"), need("Wire"), need("Hub")

local presence = Wire.presence({ id = "p", name = "ANN", surfing = true,
  airborne = true, altitude = 56, flightMount = "PIDGEOT" })
ok(presence.surfing and presence.airborne, "presence preserves literal flight surfaces")
eq(presence.altitude, 56, "presence bounds altitude")
eq(presence.flightMount, "PIDGEOT", "mount identity is separate from trainer appearance")
eq(Wire.presence({ id = "p", name = "ANN", airborne = "yes" }).airborne, false,
  "truthy junk cannot assert airborne state")

local function peer()
  return { messages = {}, send = function(self, message)
    self.messages[#self.messages + 1] = message
  end, close = function() end }
end
local hub = Hub.new({ maxPlayers = 4 })
local function connect(name)
  local wire = peer(); local client = assert(hub:accept(wire))
  hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
    name = name, map = "ROUTE_1", x = 5, y = 5 })
  wire.messages = {}; return client, wire
end
local ann, annWire = connect("ANN")
local bob, bobWire = connect("BOB")
local skyRows = {
  { id = "sky_high", species = "PIDGEOT", level = 36, x = 160, y = 96,
    alt = 56, facing = "right", mode = "roam" },
  { id = "sky_low", species = "SPEAROW", level = 5, x = 176, y = 96,
    alt = 10, facing = "left", mode = "rise" },
}
hub:receive(ann, { type = Wire.FIELD_SEED, domain = "SKY", map = "ROUTE_1",
  revision = 0, spawns = skyRows })
hub:receive(ann, { type = Wire.FIELD_CLAIM, domain = "SKY",
  map = "ROUTE_1", id = "sky_high" })
eq(annWire.messages[#annWire.messages].type, Wire.FIELD_DENIED,
  "grounded players cannot claim high flyers")
hub:receive(bob, { type = Wire.MOVE, map = "ROUTE_1", x = 6, y = 5,
  airborne = true, altitude = 56, flightMount = "PIDGEOT" })
eq(annWire.messages[#annWire.messages].flightMount, "PIDGEOT",
  "embedded hub relays remote mount identity")
hub:receive(bob, { type = Wire.FIELD_CLAIM, domain = "SKY",
  map = "ROUTE_1", id = "sky_high" })
local grant
for _, message in ipairs(bobWire.messages) do
  if message.type == Wire.FIELD_GRANTED then grant = message end
end
eq(grant and grant.id, "sky_high", "altitude-matched flyer claim is granted")
hub:receive(bob, { type = Wire.FIELD_CLAIM, domain = "SKY",
  map = "ROUTE_1", id = "sky_low" })
eq(bobWire.messages[#bobWire.messages].type, Wire.FIELD_DENIED,
  "airborne players cannot claim a distant altitude band")

local sent = {}
local transport = { isReady = function() return true end,
  send = function(_, kind, payload) sent[#sent + 1] = { kind = kind, payload = payload } end }
local SharedField = need("SharedField")
local sky = SharedField.new(transport, { selfId = "ann" }, { sorted = function() return {} end }, {
  domain = "SKY", modId = "wild_skies", snapshotExport = "sharedSkyFieldSnapshot",
  applyExport = "applySharedSkyFieldSnapshot", grantExport = "grantSharedSkyFieldContact",
  denyExport = "denySharedSkyFieldContact", clearExport = "clearSharedSkyField",
  neighborExport = "sharedSkyNeighborMaps", registerExport = "registerSharedSkyProvider",
  unregisterExport = "unregisterSharedSkyProvider", providerId = "rby_mmo",
  claimMethod = "requestClaim", claimWithSelf = false,
})
sky:update(0)
ok(skyProvider and type(skyProvider.requestClaim) == "function",
  "SKY adapter exposes the provider's receiver-free claim convention")
ok(skyProvider.requestClaim("ROUTE_1", "sky_1", { domain = "SKY" }),
  "Wild Skies can request one exact canonical claim")
eq(sent[#sent].kind, Wire.FIELD_CLAIM, "SKY claim uses the normalized wire domain")
sky:onNeeded({ domain = "SKY", map = "ROUTE_1", epoch = 0 })
eq(sent[#sent].kind, Wire.FIELD_SEED, "SKY authority seeds through provider exports")
sky:onSnapshot({ domain = "SKY", map = "ROUTE_1", epoch = 0, revision = 1,
  authority = "ann", spawns = skyExports.sharedSkyFieldSnapshot("ROUTE_1").spawns })
ok(skyApplied and skyApplied.localAuthority == true,
  "canonical SKY snapshot promotes the selected local authority")
sky:reset()
eq(unregistered, "rby_mmo", "disconnect unregisters only this companion provider")

local Client = need("Client")
eq(Client.presenceFast(false, false), false,
  "walking retains the ordinary presence cadence")
eq(Client.presenceFast(true, false), true,
  "ordinary fast movement remains fast")
eq(Client.presenceFast(false, true), true,
  "flight always advertises Free Fly's eight-frame cadence")

package.preload["src.render.SpriteRenderer"] = function()
  return { new = function() return "mount-sprite" end }
end
_G.love = { timer = { getTime = function() return 0 end } }
local Avatars = need("Avatars")
local avatars = Avatars.new()
local npc = { id = "remote", sprite = "trainer-sprite", px = 80, py = 80,
  cellX = 5, cellY = 5, facing = "right", moving = false,
  update = function() end,
  pose = function(self) return self.sprite, self.px, self.py, self.facing, 0, false, false end }
Avatars.decorate(npc)
avatars:applyFlightPresentation(npc,
  { airborne = true, altitude = 56, flightMount = "PIDGEOT" })
eq(npc.sprite, "mount-sprite", "remote avatar body becomes the flight mount")
eq(npc.mmoGroundSprite, "trainer-sprite", "trainer appearance is retained separately")
npc.mmoDisplayAltitude = 0; npc:update()
eq(npc.mmoDisplayAltitude, 1.2, "remote altitude rises at Free Fly cadence")
local av, ow = {}, { entities = {} }
local rider = avatars:syncFlightRider(av, npc, { airborne = true }, ow)
eq(#ow.entities, 1, "one display-only rider accompanies the mount")
eq(rider:pose(), "trainer-sprite", "rider uses the trainer sheet")
avatars.spawned.remote = { npc = npc, rider = rider }
eq(avatars:altitudeOf("remote"), 13.2,
  "nameplate lift includes altitude and rider clearance")
avatars:applyFlightPresentation(npc, { airborne = false, altitude = 0 })
avatars:syncFlightRider(av, npc, { airborne = false }, ow)
eq(npc.sprite, "trainer-sprite", "landing restores trainer appearance")
eq(#ow.entities, 0, "landing removes the display-only rider")

print(("\n  %d/%d checks passed  (flight and SKY)\n"):format(checks, checks))
