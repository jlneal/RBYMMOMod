-- Focused proof for the renderer-neutral four-slot presentation seam.
-- Run from the mod root: luajit tests/voxel_coop_test.lua

local passed, failed = 0, 0
local function check(value, label)
  if value then passed = passed + 1 else
    failed = failed + 1; io.stderr:write("FAIL: " .. label .. "\n")
  end
end
local function eq(actual, expected, label)
  check(actual == expected, label .. " (got " .. tostring(actual)
    .. ", wanted " .. tostring(expected) .. ")")
end

local function resolver(mod)
  local modules = {}
  local function need(name)
    if modules[name] then return modules[name] end
    local chunk = assert(loadfile("src/" .. name .. ".lua"))
    modules[name] = chunk(need, mod)
    return modules[name]
  end
  return need
end

local began, finished, snapped, worldOverride = false, false, false, nil
local backend = {
  beginBackdrop = function(ow, owner)
    began = ow and owner and true or false; return began
  end,
  shot = function() return { canvas = "voxel-canvas" } end,
  snapCoopHUDs = function(owner, shot)
    snapped = owner and shot.canvas == "voxel-canvas" and true or false
    return snapped
  end,
  finish = function() finished = true end,
}
local voxelMod = {
  log = { warn = function() end },
  find = function(_, id)
    if id == "BATTLE_ART_VOXEL_FORK" then
      return { exports = { lib = { require = function(name)
        if name == "OverworldBattle" then return backend end
      end } } }
    end
  end,
}
local need = resolver(voxelMod)
local VoxelCoop, CoopBattle = need("VoxelCoop"), need("CoopBattle")
local game = { overworld = {}, renderer = {
  setWorldOverride = function(_, canvas) worldOverride = canvas end,
} }
local owner = {}
check(VoxelCoop.available(), "the optional backend is discovered")
check(VoxelCoop.begin(game, owner), "the terrain pass accepts an external owner")
check(began, "the live overworld and owner reach the backend")
local shot = VoxelCoop.drawBackdrop(game, owner)
check(shot and shot.coopHudSnapped and snapped,
  "the backend captures the four native HUDs")
eq(worldOverride, "voxel-canvas", "the staged canvas becomes the world override")
VoxelCoop.finish()
check(finished, "finish returns presentation ownership")

check(CoopBattle.isBattleScreen, "the prototype advertises a battle screen")
local ally1, ally2 = CoopBattle.hudLayout(1), CoopBattle.hudLayout(2)
local foe1, foe2 = CoopBattle.hudLayout(3), CoopBattle.hudLayout(4)
eq(ally2.x + ally2.w, ally1.x, "allied HUDs are adjacent")
eq(foe1.x + foe1.w, foe2.x, "opposing HUDs are adjacent")
eq(ally1.y + ally1.h, 96, "allied HUDs stop at the command box")
eq(foe1.y, 0, "opposing HUDs retain the top edge")
eq(ally1.scale, 1, "HUD primitives remain native scale")
eq(CoopBattle.hudLayout(99), nil, "there is no fifth HUD")

local sprite = { getDimensions = function() return 56, 56 end }
local animScreen = setmetatable({
  sim = { slot = function(_, index)
    if index == 1 then return { side = "a" } end
    if index == 3 then return { side = "b" } end
  end },
  voxelShot = {
    coopMarks = { [1] = { 42, 104 }, [3] = { 122, 34 } },
    playerSpan = 28, enemySpan = 28,
  },
  shownBattlerAt = function() return { sprite = sprite } end,
}, { __index = CoopBattle })
local fromX, fromY = animScreen:picCenterFor(1)
local toX, toY = animScreen:picCenterFor(3)
local fromDx, fromDy = animScreen:animSpriteOffset(
  { from = 1, to = 3 }, 36, 68)
local toDx, toDy = animScreen:animSpriteOffset(
  { from = 1, to = 3 }, 116, 28)
check(math.abs(36 + fromDx - fromX) < 0.000001
      and math.abs(68 + fromDy - fromY) < 0.000001,
  "the actor endpoint maps to its projected card")
check(math.abs(116 + toDx - toX) < 0.000001
      and math.abs(28 + toDy - toY) < 0.000001,
  "the target endpoint maps independently to its projected card")

io.stdout:write(("voxel co-op presentation: %d passed\n"):format(passed))
if failed > 0 then os.exit(1) end
