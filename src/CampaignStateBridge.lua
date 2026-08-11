-- Optional transport adapter for the independent campaign_state mod. This
-- module owns no journal, reducer, content schema, save key, or projector.

local need = ...
local CampaignIdentity = need("CampaignIdentity")
local CampaignAdmission = need("CampaignAdmission")

local M = {}
M.__index = M

M.ADVERTISE = "mmo.world_advertise"
M.EVENTS = "mmo.world_events"
M.INVITE = "mmo.world_invite"
M.SEQUENCE_REQUEST = "mmo.world_sequence_request"
M.SEQUENCE_GRANT = "mmo.world_sequence_grant"
M.SEQUENCE_COMMIT = "mmo.world_sequence_commit"
M.SEQUENCE_CANCEL = "mmo.world_sequence_cancel"
M.READY = "mmo.world_ready"
M.UNAVAILABLE = "mmo.world_unavailable"
M.FRONTIER = "mmo.world_frontier"
M.FRONTIER_ACK = "mmo.world_frontier_ack"
M.FRONTIER_READY = "mmo.world_frontier_ready"
M.MAX_OUTSTANDING = 32
M.MAX_OFFERS = 16

local function tableCount(value)
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  return count
end

local function countOutstanding(self)
  return tableCount(self.pending) + tableCount(self.grants)
end

local function failPending(self, reason, cancelGranted)
  for _, pending in pairs(self.pending) do
    if type(pending.deliver) == "function" then
      pcall(pending.deliver, nil, reason)
    end
  end
  if cancelGranted then
    for token, grant in pairs(self.grants) do
      self.send(M.SEQUENCE_CANCEL, { grant = token, request = grant.request })
    end
  end
  self.pending, self.grants = {}, {}
end

function M.new(options)
  options = options or {}
  if type(options.foundation) ~= "table"
    or type(options.foundation.registerTransport) ~= "function" then
    return nil, "campaign_state exports are required"
  end
  if options.foundation.apiVersion ~= nil
    and (type(options.foundation.apiVersion) ~= "number"
      or options.foundation.apiVersion ~= math.floor(options.foundation.apiVersion)
      or options.foundation.apiVersion < 2 or options.foundation.apiVersion > 3) then
    return nil, "campaign_state API version is incompatible"
  end
  if type(options.send) ~= "function" then return nil, "send callback is required" end
  return setmetatable({ foundation = options.foundation, send = options.send,
    idFactory = options.idFactory, connected = options.connected,
    api = nil, pending = {}, grants = {}, offers = {}, serial = 0,
    frontierAdmission = options.frontierAdmission == true,
    admission = nil, admittedBase = nil, authorityRevision = nil,
    authorized = false, blocked = nil }, M)
end

function M:requestId()
  self.serial = self.serial + 1
  local value = self.idFactory and self.idFactory("world-request", self.serial)
    or ("world-request-" .. tostring(self.serial))
  return CampaignIdentity.identifier(value, 64)
end

function M:install()
  local authority = {
    available = function()
      return type(self.connected) ~= "function" or self.connected() == true
    end,
    request = function(_, actor, kind, subject, deliver)
      if type(self.connected) == "function" and self.connected() ~= true then
        return nil, "multiplayer transport is offline"
      end
      if self.blocked then return nil, self.blocked end
      if not self.authorized then return nil, "shared-world authority handshake is pending" end
      if countOutstanding(self) >= M.MAX_OUTSTANDING then
        return nil, "too many outstanding shared-world reservations"
      end
      local request = self:requestId()
      if not request then return nil, "sequence request identity is invalid" end
      self.pending[request] = { actor = actor, kind = kind, subject = subject,
        deliver = deliver }
      local payload = { request = request, actor = actor,
        kind = kind, subject = subject }
      if self.frontierAdmission then payload.base = self.admittedBase end
      self.send(M.SEQUENCE_REQUEST, payload)
      return "pending"
    end,
    permits = function(_, token, actor, kind, subject)
      local grant = self.grants[token]
      if not grant or grant.actor ~= actor or grant.kind ~= kind
        or grant.subject ~= subject then return nil, "grant does not match" end
      return true
    end,
    commit = function(_, token, events)
      local grant = self.grants[token]
      if not grant then return nil, "grant is unavailable" end
      if not self.api or type(self.api.batch) ~= "function" then
        return nil, "campaign event signing is unavailable"
      end
      local envelope, why = self.api.batch(events)
      if not envelope then return nil, why end
      -- Ordered on one reliable MMO connection: peers receive the signed
      -- occupant before the hub releases its position to the next writer.
      self.send(M.EVENTS, { envelope = envelope })
      self.send(M.SEQUENCE_COMMIT, { grant = token, request = grant.request,
        position = grant.position })
      self.grants[token] = nil
      return grant.position
    end,
    cancel = function(_, token)
      local grant = self.grants[token]
      if not grant then return false end
      self.send(M.SEQUENCE_CANCEL, { grant = token, request = grant.request })
      self.grants[token] = nil
      return true
    end,
  }
  return self.foundation.registerTransport("rby-mmo", {
    send = self.send,
    authority = authority,
    attach = function(api)
      self.api = api
      if self.frontierAdmission then
        local admission, why = CampaignAdmission.new(api)
        if not admission then error(why) end
        self.admission = admission
      end
    end,
    lifecycle = function(reason, active)
      self:reset(reason)
      if active and (type(self.connected) ~= "function" or self.connected() == true) then
        return self:advertise()
      end
      return true
    end,
    publish = function() return self:advertise() end,
    publishBatch = function() return self:advertise() end,
  })
end

function M:onInvitation(from, invitation)
  local id = CampaignIdentity.identifier(from, 64)
  if not id or type(invitation) ~= "table" then return nil, "invitation is invalid" end
  if not self.offers[id] and tableCount(self.offers) >= M.MAX_OFFERS then
    return nil, "too many pending world invitations"
  end
  self.offers[id] = invitation
  return true
end

function M:offer(from)
  return self.offers[CampaignIdentity.identifier(from, 64)]
end

function M:acceptFrom(from)
  local id = CampaignIdentity.identifier(from, 64)
  local invitation = id and self.offers[id]
  if not invitation then return nil, "world invitation is unavailable" end
  local ok, why = self:accept(invitation)
  if ok then
    self.offers[id] = nil
    if type(self.connected) ~= "function" or self.connected() == true then
      self:advertise()
    end
  end
  return ok, why
end

function M:advertise()
  if not self.api then return nil, "campaign transport is not attached" end
  if self.frontierAdmission and countOutstanding(self) > 0 then
    failPending(self, "canonical frontier changed", true)
  end
  local inventory, why = self.api.inventory()
  if not inventory then return nil, why end
  local frontier
  if self.frontierAdmission then
    frontier, why = self.api.frontier()
    if not frontier then return nil, why end
    self.admission:reset("new frontier advertisement")
  end
  self.admittedBase = nil
  self.authorityRevision = nil
  self.authorized, self.blocked = false, nil
  self.send(M.ADVERTISE, { inventory = inventory, frontier = frontier })
  return true
end

function M:onReady(raw)
  if self.frontierAdmission then
    return nil, "protocol-19 frontier acknowledgement is required"
  end
  if type(raw) ~= "table" or not self.api then return nil, "authority reply is invalid" end
  local status = self.api.status and self.api.status() or nil
  if type(status) ~= "table" or raw.world ~= status.worldId
    or raw.player ~= status.playerId then return nil, "authority reply does not match save" end
  self.authorized, self.blocked = true, nil
  return true
end

function M:onFrontier(raw)
  if not self.frontierAdmission or not self.admission then
    return nil, "frontier admission is not enabled"
  end
  local revision = type(raw) == "table" and raw.revision or nil
  if self.authorityRevision and revision ~= self.authorityRevision
    and countOutstanding(self) > 0 then
    failPending(self, "canonical frontier changed", true)
  end
  self.authorityRevision = revision
  self.authorized, self.admittedBase = false, nil
  local result, why = self.admission:observe(raw)
  if not result then
    self.blocked = why or "canonical frontier admission failed"
    failPending(self, self.blocked, true)
    return nil, self.blocked
  end
  if result.state == "acknowledging" then
    self.blocked = nil
    self.send(M.FRONTIER_ACK, { admission = result })
  elseif result.state == "frozen" then
    self.blocked = result.reason or "canonical frontier is frozen"
    failPending(self, self.blocked, true)
  else
    self.blocked = nil
  end
  return result
end

function M:onFrontierReady(raw)
  if not self.frontierAdmission or not self.admission then
    return nil, "frontier admission is not enabled"
  end
  local ok, why = self.admission:confirm(raw)
  if not ok then
    self.authorized, self.admittedBase = false, nil
    self.blocked = why
    failPending(self, why, true)
    return nil, why
  end
  self.admittedBase = CampaignAdmission.normalizeBase(raw.grantBase)
  self.authorityRevision = raw.authorityRevision
  self.authorized, self.blocked = true, nil
  return true
end

function M:onUnavailable(reason)
  self.authorized = false
  self.blocked = reason == "duplicate_player"
    and "this shared-world player is already connected"
    or "shared-world authority is unavailable"
  failPending(self, self.blocked, true)
  return true
end

function M:active()
  if not self.api or type(self.api.status) ~= "function" then return false end
  local status = self.api.status()
  return type(status) == "table" and status.active == true
end

function M:onInventory(from, inventory)
  if not self.api then return nil, "campaign transport is not attached" end
  local batches, why = self.api.missing(inventory)
  if not batches then return nil, why end
  for _, envelope in ipairs(batches) do
    self.send(M.EVENTS, { to = from, envelope = envelope })
  end
  return #batches
end

function M:onEvents(envelope)
  if not self.api then return nil, "campaign transport is not attached" end
  local accepted, why = self.api.receive(envelope)
  if accepted and accepted > 0 and self.frontierAdmission then self:advertise() end
  return accepted, why
end

function M:invite(to)
  local invitation, why = self.foundation.invitation()
  if not invitation then return nil, why end
  self.send(M.INVITE, { to = to, invitation = invitation })
  return true
end

function M:accept(invitation)
  return self.foundation.acceptInvitation(invitation)
end

function M:onGrant(raw)
  if type(raw) ~= "table" then return nil, "sequence grant is invalid" end
  local request = CampaignIdentity.identifier(raw.request, 64)
  local token = CampaignIdentity.identifier(raw.grant, 96)
  local world = CampaignIdentity.identifier(raw.world, 64)
  local position = tonumber(raw.position)
  local pending = request and self.pending[request]
  if not (pending and token and world and position
    and position == math.floor(position) and position >= 1) then
    return nil, "sequence grant is invalid"
  end
  if self.frontierAdmission then
    local valid, why = self.admission:validate(raw.base)
    if not valid then
      self.pending[request] = nil
      self.authorized, self.admittedBase = false, nil
      self.blocked = why
      self.send(M.SEQUENCE_CANCEL, { grant = token, request = request })
      if type(pending.deliver) == "function" then pcall(pending.deliver, nil, why) end
      return nil, why
    end
  end
  self.pending[request] = nil
  local grant = { request = request, grant = token, world = world,
    position = position, actor = pending.actor, kind = pending.kind,
    subject = pending.subject }
  self.grants[token] = grant
  if type(pending.deliver) == "function" then
    local ok, why = pcall(pending.deliver, grant)
    if not ok then
      self.send(M.SEQUENCE_CANCEL, { grant = token, request = request })
      self.grants[token] = nil
      return nil, "sequence grant delivery failed: " .. tostring(why)
    end
  end
  return grant
end

function M:reset(reason)
  failPending(self, reason or "multiplayer transport disconnected", true)
  self.offers = {}
  if self.admission then self.admission:reset(reason) end
  self.admittedBase = nil
  self.authorityRevision = nil
  self.authorized, self.blocked = false, nil
  return true
end

return M
