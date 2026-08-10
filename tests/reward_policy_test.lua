-- Focused proof for host-owned trainer co-op rewards.
-- Run from the mod root: luajit tests/reward_policy_test.lua

local passed, failed = 0, 0
local function check(value, label)
  if value then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write("FAIL: " .. label .. "\n")
  end
end
local function eq(actual, expected, label)
  check(actual == expected, label .. " (got " .. tostring(actual)
    .. ", wanted " .. tostring(expected) .. ")")
end

local modules = {}
local stubMod = {
  log = { warn = function() end },
  options = { get = function() return nil end },
  save = { get = function() return nil end, set = function() end },
}
local function need(name)
  if modules[name] then return modules[name] end
  local chunk = assert(loadfile("src/" .. name .. ".lua"))
  modules[name] = chunk(need, stubMod)
  return modules[name]
end

local Config = need("Config")
local Wire = need("Wire")
local Coop = need("Coop")
local CoopBattle = need("CoopBattle")
local Hub = need("Hub")

eq(Config.DEFAULT_COOP_EXP_ENABLED, true, "co-op EXP defaults on")
eq(Config.DEFAULT_COOP_MONEY_ENABLED, true, "co-op money defaults on")
eq(Config.rewardEnabled(nil, true), true, "missing setting uses true fallback")
eq(Config.rewardEnabled(nil, false), false, "missing setting uses false fallback")
eq(Config.rewardEnabled("off", true), false, "off is false")
eq(Config.rewardEnabled("yes", false), true, "yes is true")

local outbox = {}
local peer = {
  send = function(_, message) outbox[#outbox + 1] = message end,
  close = function() end,
}
local hub = Hub.new({ coopExpEnabled = false, coopMoneyEnabled = true })
local client = assert(hub:accept(peer))
hub:receive(client, {
  type = Wire.HELLO, proto = Config.PROTOCOL, name = "RED",
})
local welcome
for _, message in ipairs(outbox) do
  if message.type == Wire.WELCOME then welcome = message end
end
check(welcome ~= nil, "embedded hub welcomes the player")
eq(welcome.coopExpEnabled, false, "embedded hub publishes EXP policy")
eq(welcome.coopMoneyEnabled, true, "embedded hub publishes money policy")

local function mon() return { species = "PIKACHU", level = 5 } end
local field = { host = "host", trainer = "YOUNGSTER", slots = {} }
for i = 1, Config.COOP_FIGHTERS do
  field.slots[i] = {
    side = i < 3 and "a" or "b",
    owner = i < 3 and ("p" .. i) or nil,
    name = i < 3 and ("PLAYER" .. i) or "YOUNGSTER",
    party = { mon() },
  }
end
local oldField = Wire.coopField(field)
check(oldField ~= nil, "legacy field remains valid")
eq(oldField.rewardExp, true, "legacy field defaults EXP on")
eq(oldField.rewardMoney, true, "legacy field defaults money on")
field.rewardExp, field.rewardMoney = false, false
local disabledField = Wire.coopField(field)
eq(disabledField.rewardExp, false, "field preserves disabled EXP")
eq(disabledField.rewardMoney, false, "field preserves disabled money")

local coop = Coop.new({}, {}, {}, {}, {}, function() return false end,
  function() return true end)
eq(coop:coopExpAllowed(), false, "EXP callback controls policy")
eq(coop:coopMoneyAllowed(), true, "money callback is independent")

local function member(id) return { id = id, name = id } end
local parties = {
  a1 = { { hp = 5 } }, a2 = { { hp = 5 } },
  b1 = { { hp = 5 } }, b2 = { { hp = 5 } },
}
local pvp = { plan = {
  hostId = "a1", allies = { member("a1"), member("a2") },
  foes = { member("b1"), member("b2") },
}, parties = parties, badges = {} }
local pvpField = assert(coop:buildField({}, pvp, {}))
eq(pvpField.rewardExp, false, "PvP never pays ordinary EXP")
eq(pvpField.rewardMoney, false, "PvP never pays trainer prize money")

local npcCoop = Coop.new({}, {}, {}, {}, {}, function() return false end,
  function() return true end)
npcCoop.npcSide = function()
  return {
    { side = "b", name = "TRAINER", party = { { hp = 5 } } },
    { side = "b", name = "TRAINER", party = { { hp = 5 } } },
  }
end
local npcBattle = { plan = {
  hostId = "a1", allies = { member("a1"), member("a2") },
  engine = { trainer = { id = "YOUNGSTER" } },
}, parties = parties, badges = {} }
local npcField = assert(npcCoop:buildField({}, npcBattle, {}))
eq(npcField.rewardExp, false, "NPC field carries the EXP switch")
eq(npcField.rewardMoney, true, "NPC money switch remains independent")

local finished
local save = { money = 100 }
local payout = setmetatable({ encounter = {
  game = { save = save },
  engine = {
    trainer = { baseMoney = 10 }, enemyParty = { { level = 12 } },
    onFinish = function(result) finished = result end,
  },
} }, { __index = Coop })
payout:consume("win", false, false)
eq(save.money, 100, "disabled money does not mutate the save")
eq(finished, "win", "disabling money still completes the trainer battle")

local expBattle = setmetatable({ rewardExp = false, mine = 1 },
  { __index = CoopBattle })
eq(expBattle:gainExp({ slot = 1 }), false,
  "disabled EXP returns before touching battle state")

io.write(("reward policy: %d passed, %d failed\n"):format(passed, failed))
if failed > 0 then os.exit(1) end
