-- Focused proof for proximity-join ownership and distance semantics.
-- Run from the mod root: luajit tests/proximity_policy_test.lua

local passed, failed = 0, 0
local function check(value, label)
  if value then passed = passed + 1 else
    failed = failed + 1
    io.stderr:write("FAIL: " .. label .. "\n")
  end
end
local function eq(actual, expected, label)
  check(actual == expected, label .. " (got " .. tostring(actual)
    .. ", wanted " .. tostring(expected) .. ")")
end

local modules = {}
local stubMod = { log = { warn = function() end } }
local function need(name)
  if modules[name] then return modules[name] end
  modules[name] = assert(loadfile("src/" .. name .. ".lua"))(need, stubMod)
  return modules[name]
end

local Config = need("Config")
local Wire = need("Wire")
local Coop = need("Coop")
local Hub = need("Hub")

eq(Config.clampAutoJoinRange(-3), 0, "range clamps at zero")
eq(Config.clampAutoJoinRange(99), 8, "range clamps at eight")
eq(Config.clampAutoJoinRange(3.9), 3, "range is an integer tile count")
eq(Config.proximityEnabled(nil), false, "host permission defaults off")

local here = { mapId = "ROUTE_1", x = 10, y = 10 }
eq(Coop.withinAutoJoin(here, { map = "ROUTE_1", x = 13, y = 12 }, 3),
  true, "Chebyshev boundary is inclusive")
eq(Coop.withinAutoJoin(here, { map = "ROUTE_1", x = 14, y = 10 }, 3),
  false, "one tile outside is refused")
eq(Coop.withinAutoJoin(here, { map = "VIRIDIAN", x = 10, y = 10 }, 8),
  false, "another map is never nearby")
eq(Coop.withinAutoJoin(here, { map = "ROUTE_1", x = 10, y = 10 }, 0),
  false, "zero range is client opt-out")

local sent = {}
local coop = Coop.new({ send = function(_, kind, payload)
  sent[#sent + 1] = { kind = kind, payload = payload }
end }, {}, { isPartner = function(_, id) return id == "p2" end }, {
  get = function(_, id)
    if id == "p2" then return { map = "ROUTE_1", x = 12, y = 10 } end
  end,
}, { add = function() end }, nil, nil,
function() return true end, function() return 2 end,
function() return here end)
coop.note = function() end
coop:onOffer({}, {
  from = "p2", name = "BLUE", battle = "ROUTE_1|TRAINER", map = "ROUTE_1",
})
eq(#sent, 1, "nearby opted-in client sends one automatic join")
eq(sent[1].kind, Wire.COOP_JOIN, "automatic handoff uses the normal join type")
eq(sent[1].payload.auto, true, "automatic handoff is explicitly marked")

sent = {}
coop.proximityJoinEnabled = function() return false end
coop:onOffer({}, {
  from = "p2", name = "BLUE", battle = "ROUTE_1|TRAINER", map = "ROUTE_1",
})
eq(#sent, 0, "host denial suppresses automatic joins")

local outbox = {}
local peer = { send = function(_, msg) outbox[#outbox + 1] = msg end,
  close = function() end }
local hub = Hub.new({ proximityJoinEnabled = true })
local client = assert(hub:accept(peer))
hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "RED" })
local welcome
for _, msg in ipairs(outbox) do if msg.type == Wire.WELCOME then welcome = msg end end
eq(welcome and welcome.proximityJoinEnabled, true,
  "embedded host publishes its latched policy")

io.write(("proximity policy: %d passed, %d failed\n"):format(passed, failed))
if failed > 0 then os.exit(1) end
