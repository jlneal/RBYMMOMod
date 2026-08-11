-- Run from a Gen1Recomp checkout with this mod at mods/rby_mmo and the
-- independent framework at mods/campaign_state.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local inner = T.fs.new(".")
local body = "return { mods = { campaign_state = true, rby_mmo = true } }"
local loadstr = loadstring or load
local fs = { root = inner.root }

function fs.read(path)
  if path == "options.lua" then return body end
  local value = inner.read(path)
  -- A source checkout identifies itself as 0.0.0-dev. Keep the production
  -- manifest strict while letting this headless compatibility proof run
  -- against that checkout.
  if path == "mods/campaign_state/manifest.json" and type(value) == "string" then
    value = value:gsub(">=0%.1%.75 <2%.0%.0", ">=0.0.0-0 <2.0.0")
  end
  return value
end

function fs.load(path)
  if path == "options.lua" then return loadstr(body, "options.lua") end
  return inner.load(path)
end

function fs.getInfo(path)
  if path == "options.lua" then return { type = "file" } end
  return inner.getInfo(path)
end

function fs.getDirectoryItems(path)
  if path == "mods" then return { "campaign_state", "rby_mmo" } end
  return inner.getDirectoryItems(path)
end

local run = T.sdk.loadMods({ "mods/campaign_state", "mods/rby_mmo" }, { fs = fs })
T.eq(#run.errors, 0, "Campaign State and RBY MMO load together")
T.eq(run.mods.campaign_state.state, "loaded", "Campaign State loads first")
T.eq(run.mods.rby_mmo.state, "loaded", "RBY MMO loads with its optional dependency")

local invite, why = run.loader.exports.rby_mmo.inviteSharedWorld("peer")
T.eq(invite, nil, "an inactive campaign cannot mint an invitation")
T.check(not tostring(why):find("transport is unavailable", 1, true),
  "RBY MMO attached the Campaign State transport facade")

run.release()
T.finish("campaign loader")
