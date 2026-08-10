-- Optional bridge to Dramatic Shape's staged overworld-battle camera.
-- The four-slot MMO screen keeps all simulation and UI ownership; the voxel
-- mod contributes only a transparent terrain backdrop in this prototype.
local _, mod = ...

local M = {}
local backend, looked
local activeOwner

local function findBackend()
  if looked then return backend end
  looked = true
  if not (mod and type(mod.find) == "function") then return nil end
  local ok, hit = pcall(mod.find, mod, "BATTLE_ART_VOXEL_FORK")
  local lib = ok and hit and hit.exports and hit.exports.lib
  if not (lib and type(lib.require) == "function") then return nil end
  local got, value = pcall(lib.require, "OverworldBattle")
  if got and type(value) == "table"
     and type(value.beginBackdrop) == "function" then backend = value end
  return backend
end

function M.begin(game, owner)
  local b = findBackend()
  local ow = game and game.overworld
  if not (b and ow) then return false end
  local ok, started = pcall(b.beginBackdrop, ow, owner)
  if ok and started == true then activeOwner = owner; return true end
  return false
end

function M.ensure(game, owner)
  local b = findBackend()
  if not b then return false end
  if type(b.ownsBackdrop) == "function" then
    local ok, owns = pcall(b.ownsBackdrop, owner)
    if ok and owns == true then activeOwner = owner; return true end
  elseif activeOwner == owner then
    return true
  end
  return M.begin(game, owner)
end

function M.shot()
  local b = findBackend()
  if not (b and type(b.shot) == "function") then return nil end
  local ok, shot = pcall(b.shot)
  return ok and shot or nil
end

function M.finish()
  local b = findBackend()
  if b and type(b.finish) == "function" then pcall(b.finish) end
  activeOwner = nil
end

function M.drawBackdrop(game, owner)
  local b = findBackend()
  if not b then return nil end
  if owner and not M.ensure(game, owner) then return nil end
  local shot = M.shot()
  local renderer = game and game.renderer
  if not (shot and shot.canvas and renderer and renderer.setWorldOverride) then
    return nil
  end
  shot.coopHudSnapped = false
  if type(b.snapCoopHUDs) == "function" then
    local hudOk, snappedHud = pcall(b.snapCoopHUDs, owner, shot)
    shot.coopHudSnapped = hudOk and snappedHud == true or false
  end
  local ok = pcall(renderer.setWorldOverride, renderer, shot.canvas)
  if not ok then return nil end
  if love and love.graphics and love.graphics.clear then
    pcall(love.graphics.clear, 0, 0, 0, 0)
  end
  return shot
end

function M.available()
  return findBackend() ~= nil
end

return M

