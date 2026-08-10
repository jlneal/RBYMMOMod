-- Shared presentation state for ordinary random-walking engine NPCs.
--
-- Story state stays local: this never creates, removes, reveals, talks to, or
-- marks an NPC defeated. Trainer objects are excluded. A local script or
-- dialogue retains priority while it owns an otherwise eligible walker.
local need, mod = ...

local M = {}
M.__index = M

local function prefix(mapId)
  return "^" .. tostring(mapId):gsub("([^%w])", "%%%1") .. "_obj_%d+$"
end

local function ordinaryWalker(npc, mapId)
  return type(npc) == "table" and type(npc.def) == "table"
    and npc.def.runtime ~= true and npc.def.movement == "WALK"
    and npc.def.trainerClass == nil and type(npc.id) == "string"
    and npc.id:match(prefix(mapId)) ~= nil
end

local function overworld()
  local world = mod and mod.world
  if not (world and world.overworld) then return nil end
  local ok, ow = pcall(world.overworld, world)
  return ok and ow or nil
end

local function scriptOwns(ow, npc)
  for _, move in ipairs((ow and ow.scriptMoves) or {}) do
    if move.entity == npc then return true end
  end
  return false
end

local function localScriptBusy(ow, mapId)
  if not (ow and ow.map and ow.map.id == mapId) then return false end
  local runner = ow.runner
  return runner and type(runner.isRunning) == "function" and runner:isRunning() == true
end

local function setPixels(npc)
  local px, py = (npc.cellX or 0) * 16, (npc.cellY or 0) * 16
  if npc.moving and not npc.marching and npc.targetX and npc.targetY then
    local progress = tonumber(npc.progress) or 0
    px = px + (npc.targetX - npc.cellX) * progress
    py = py + (npc.targetY - npc.cellY) * progress
  end
  npc.px, npc.py = px, py
end

function M.new() return setmetatable({ touched = {}, authority = {} }, M) end

function M:snapshot(mapId)
  local ow = overworld()
  if not (ow and type(ow.npcPool) == "table") then return nil end
  local rows = {}
  for _, npc in pairs(ow.npcPool) do
    if ordinaryWalker(npc, mapId) then
      rows[#rows + 1] = { id = npc.id, x = npc.cellX, y = npc.cellY,
        facing = npc.facing or "down", moving = npc.moving == true,
        targetX = npc.targetX, targetY = npc.targetY, progress = npc.progress or 0,
        marching = npc.marching == true, stepFlip = npc.stepFlip == true }
    end
  end
  table.sort(rows, function(a, b) return a.id < b.id end)
  return { map = mapId, spawns = rows }
end

function M:apply(snapshot)
  local mapId = snapshot and snapshot.map
  local ow = overworld()
  if not (type(mapId) == "string" and type(snapshot.spawns) == "table"
      and ow and type(ow.npcPool) == "table") then return false end
  local busy = localScriptBusy(ow, mapId)
  local alreadyAuthority = self.authority[mapId] == true
  for _, row in ipairs(snapshot.spawns) do
    local npc = ow.npcPool[row.id]
    if ordinaryWalker(npc, mapId) then
      if npc._mmoBaseWanders == nil then npc._mmoBaseWanders = npc.wanders == true end
      self.touched[npc] = true
      npc.wanders = snapshot.localAuthority == true and npc._mmoBaseWanders or false
      if not busy and not scriptOwns(ow, npc)
         and not (snapshot.localAuthority == true and alreadyAuthority) then
        npc.cellX, npc.cellY = row.x, row.y
        npc.facing = row.facing or npc.facing
        npc.moving, npc.marching = row.moving == true, row.marching == true
        npc.targetX, npc.targetY = row.targetX, row.targetY
        npc.progress, npc.stepFlip = row.progress or 0, row.stepFlip == true
        setPixels(npc)
      end
    end
  end
  self.authority[mapId] = snapshot.localAuthority == true
  return true
end

function M:clear()
  for npc in pairs(self.touched) do
    if type(npc) == "table" then
      npc.wanders = npc._mmoBaseWanders == true
      npc._mmoBaseWanders = nil
    end
  end
  self.touched, self.authority = {}, {}
  return true
end

function M:neighbors()
  local ow, out = overworld(), {}
  for _, neighbor in ipairs((ow and ow.neighbors) or {}) do
    if neighbor.map and neighbor.map.id then out[#out + 1] = neighbor.map.id end
  end
  return out
end

return M
