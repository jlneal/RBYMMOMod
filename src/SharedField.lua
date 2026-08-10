-- Transport adapter for one session-scoped field domain.
--
-- Providers own generation, rendering, collision, and local simulation. This
-- module owns only discovery, registration, requests, revisions, leases, and
-- atomic claim messages. It depends on provider exports rather than a renderer
-- or a concrete Wilds implementation.
local need, mod = ...
local Wire = need("Wire")
local World = need("World")

local M = {}
M.__index = M

local PUBLISH_INTERVAL = 0.5

local function sig(value) return value == nil and "" or tostring(value) end

local function signature(snapshot)
  local rows = {}
  for _, row in ipairs((snapshot and snapshot.spawns) or {}) do
    rows[#rows + 1] = table.concat({ sig(row.id), sig(row.species), sig(row.level),
      sig(row.x), sig(row.y), sig(row.alt), sig(row.vx), sig(row.vy),
      sig(row.facing), sig(row.behavior), sig(row.surface), sig(row.kind),
      sig(row.mode), row.bold and "1" or "0", sig(row.target), sig(row.aggro),
      row.moving and "1" or "0", sig(row.targetX), sig(row.targetY),
      sig(row.progress), row.marching and "1" or "0",
      row.stepFlip and "1" or "0" }, ":")
  end
  table.sort(rows)
  return table.concat(rows, "|")
end

local function strictId(value)
  return type(value) == "string" and #value <= 40 and Wire.id(value) or nil
end

function M.new(transport, identity, roster, opts)
  opts = opts or {}
  return setmetatable({
    transport = transport, identity = identity, roster = roster,
    domain = opts.domain or "GROUND",
    modId = opts.modId or "overworld_wild_spawns",
    snapshotExport = opts.snapshotExport or "sharedFieldSnapshot",
    applyExport = opts.applyExport or "applySharedFieldSnapshot",
    removeExport = opts.removeExport or "removeSharedFieldSpawn",
    grantExport = opts.grantExport or "grantSharedFieldContact",
    denyExport = opts.denyExport or "denySharedFieldContact",
    clearExport = opts.clearExport or "clearSharedField",
    resetExport = opts.resetExport,
    neighborExport = opts.neighborExport or "sharedNeighborMaps",
    registerExport = opts.registerExport,
    exports = opts.exports,
    acceptContact = opts.acceptContact,
    publishInterval = opts.publishInterval or PUBLISH_INTERVAL,
    map = nil, clock = 0, total = 0, requested = {},
    snapshots = {}, authorities = {}, registered = nil,
  }, M)
end

function M:active()
  return self.transport and self.transport.isReady
    and self.transport:isReady() == true
end

function M:providerExports()
  if self.exports then return self.exports end
  if not (mod and type(mod.find) == "function") then return nil end
  local ok, hit = pcall(mod.find, mod, self.modId)
  return ok and hit and type(hit.exports) == "table" and hit.exports or nil
end

function M:selfId()
  return self.identity and strictId(self.identity.selfId) or nil
end

function M:targets(map)
  map = Wire.mapId(map)
  local selfId = self:selfId()
  if not (map and selfId and self:active()) then return {} end
  local out = {}
  local current = World.current()
  local world = mod and mod.world
  local ow
  if world and world.overworld then
    local ok, value = pcall(world.overworld, world)
    if ok then ow = value end
  end
  if current and current.mapId == map and ow and ow.player then
    out[#out + 1] = { id = selfId, localPlayer = true,
      x = ow.player.cellX, y = ow.player.cellY,
      facing = ow.player.facing or current.facing,
      surfing = ow.player.surfing == true }
  end
  for _, player in ipairs((self.roster and self.roster:sorted()) or {}) do
    if player.map == map and player.x ~= nil and player.y ~= nil and not player.busy then
      out[#out + 1] = { id = player.id, localPlayer = false,
        x = player.x, y = player.y, facing = player.facing }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M:register()
  if not self.registerExport then return true end
  local ex = self:providerExports()
  if not (ex and type(ex[self.registerExport]) == "function") then return false end
  if self.registered == ex then return true end
  local adapter = self
  local provider = {
    claim = function(_, map, id) return adapter:claim(map, id) end,
    targets = function(_, map) return adapter:targets(map) end,
    acceptContact = function(_, map, id, target)
      if type(adapter.acceptContact) ~= "function" then return false end
      return adapter.acceptContact(map, id, target) == true
    end,
  }
  local ok, accepted = pcall(ex[self.registerExport], provider)
  if not (ok and accepted ~= false) then return false end
  self.registered = ex
  return true
end

function M:reset()
  local ex = self.registered or self:providerExports()
  if ex and type(ex[self.clearExport]) == "function" then pcall(ex[self.clearExport]) end
  self.registered = nil
  self.map, self.clock, self.total = nil, 0, 0
  self.requested, self.snapshots, self.authorities = {}, {}, {}
end

function M:request(map)
  map = Wire.mapId(map)
  if not (map and self:active()) then return false end
  self.transport:send(Wire.FIELD_REQUEST, { domain = self.domain, map = map })
  self.requested[map] = self.total
  return true
end

function M:localSnapshot(map, revision, epoch)
  local ex = self:providerExports()
  if not (ex and type(ex[self.snapshotExport]) == "function") then return nil end
  local ok, raw = pcall(ex[self.snapshotExport], map)
  if not ok or type(raw) ~= "table" then return nil end
  raw.domain, raw.map, raw.revision = self.domain, map, revision or 0
  raw.epoch = epoch or 0
  return Wire.fieldSnapshot(raw)
end

function M:onNeeded(msg)
  if not self:active() or (msg and msg.domain or "GROUND") ~= self.domain then return end
  local map = Wire.mapId(msg and msg.map)
  if not map then return end
  local epoch = Wire.int(msg and msg.epoch or 0, 0, 2147483647) or 0
  if msg and msg.reset == true then
    local ex = self:providerExports()
    if ex and self.resetExport and type(ex[self.resetExport]) == "function" then
      pcall(ex[self.resetExport], map, epoch)
    end
    self.snapshots[map], self.authorities[map] = nil, nil
  end
  local snapshot = self:localSnapshot(map, 0, epoch)
  if snapshot then self.transport:send(Wire.FIELD_SEED, snapshot) end
end

function M:onSnapshot(msg)
  if not self:active() then return end
  local snapshot = Wire.fieldSnapshot(msg)
  if not snapshot or snapshot.domain ~= self.domain then return end
  local authority = strictId(msg and msg.authority) or false
  local old = self.snapshots[snapshot.map]
  if old and (snapshot.epoch < old.epoch or
      (snapshot.epoch == old.epoch and snapshot.revision < old.revision)) then return end
  self.snapshots[snapshot.map] = snapshot
  self.requested[snapshot.map] = nil
  self.authorities[snapshot.map] = authority

  local ex = self:providerExports()
  if ex and type(ex[self.applyExport]) == "function" then
    snapshot.localAuthority = authority ~= false and authority == self:selfId()
    snapshot.localPlayerId = self:selfId()
    pcall(ex[self.applyExport], snapshot)
  end
end

function M:consume(map, id)
  map, id = Wire.mapId(map), strictId(id)
  if not (self:active() and map and id) then return false end
  self.transport:send(Wire.FIELD_CONSUME, { domain = self.domain, map = map, id = id })
  local ex = self:providerExports()
  if ex and type(ex[self.removeExport]) == "function" then pcall(ex[self.removeExport], id) end
  return true
end

function M:claim(map, id)
  map, id = Wire.mapId(map), strictId(id)
  if not (self:active() and map and id) then return false end
  self.transport:send(Wire.FIELD_CLAIM, { domain = self.domain, map = map, id = id })
  return true
end

function M:onGranted(msg)
  if (msg and msg.domain or "GROUND") ~= self.domain then return false end
  local map, id = Wire.mapId(msg and msg.map), strictId(msg and msg.id)
  if not (map and id and self:active()) then return false end
  local ex = self:providerExports()
  if not (ex and type(ex[self.grantExport]) == "function") then return false end
  local ok, accepted = pcall(ex[self.grantExport], map, id)
  return ok and accepted == true
end

function M:onDenied(msg)
  if (msg and msg.domain or "GROUND") ~= self.domain then return false end
  local map, id = Wire.mapId(msg and msg.map), strictId(msg and msg.id)
  if not (map and id and self:active()) then return false end
  local ex = self:providerExports()
  if not (ex and type(ex[self.denyExport]) == "function") then return false end
  local ok, denied = pcall(ex[self.denyExport], map, id)
  return ok and denied == true
end

function M:update(dt)
  if not self:active() then
    if self.map or self.registered then self:reset() end
    return
  end
  if not self:register() then return end

  self.total = self.total + (tonumber(dt) or 0)
  local current = World.current()
  local map = current and Wire.mapId(current.mapId)
  if map ~= self.map then
    self.map, self.clock = map, 0
    if map then self:request(map) end
  end

  local ex = self:providerExports()
  if ex and type(ex[self.neighborExport]) == "function" then
    local ok, maps = pcall(ex[self.neighborExport])
    if ok and type(maps) == "table" then
      for _, neighbor in ipairs(maps) do
        neighbor = Wire.mapId(neighbor)
        local last = neighbor and self.requested[neighbor]
        if neighbor and not self.snapshots[neighbor]
           and (last == nil or self.total - last >= 2) then self:request(neighbor) end
      end
    end
  end
  if not map then return end

  local canonical, authority = self.snapshots[map], self.authorities[map]
  if not (canonical and authority and authority == self:selfId()) then return end
  self.clock = self.clock + (tonumber(dt) or 0)
  if self.clock < self.publishInterval then return end
  self.clock = 0
  local nextSnapshot = self:localSnapshot(map, canonical.revision, canonical.epoch)
  if nextSnapshot and signature(nextSnapshot) ~= signature(canonical) then
    self.transport:send(Wire.FIELD_PUBLISH, nextSnapshot)
  end
end

function M:state()
  local snapshot = self.map and self.snapshots[self.map] or nil
  return snapshot and { map = snapshot.map, epoch = snapshot.epoch,
    revision = snapshot.revision, authority = self.authorities[snapshot.map],
    count = #snapshot.spawns } or nil
end

return M
