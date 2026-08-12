-- Optional transport adapter for the independent campaign_state mod. This
-- module owns no journal, reducer, content schema, save key, or projector.

local need = ...
local CampaignIdentity = need("CampaignIdentity")
local CampaignAdmission = need("CampaignAdmission")
local CampaignWire = need("CampaignWire")

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
M.PREFIX = "mmo.world_prefix"
M.PREFIX_FRAME = "mmo.world_prefix_frame"
M.PREFIX_FRAME_ACK = "mmo.world_prefix_frame_ack"
M.ARCHIVE_BEGIN = "mmo.world_archive_begin"
M.ARCHIVE_BATCH = "mmo.world_archive_batch"
M.ARCHIVE_END = "mmo.world_archive_end"
M.ARCHIVE_NEEDED = "mmo.world_archive_needed"
M.ARCHIVE_READY = "mmo.world_archive_ready"
M.MAX_OUTSTANDING = 32
M.MAX_OFFERS = 16
M.MAX_PREFIX_STREAMS = 8

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
      or options.foundation.apiVersion < 2 or options.foundation.apiVersion > 4) then
    return nil, "campaign_state API version is incompatible"
  end
  if type(options.send) ~= "function" then return nil, "send callback is required" end
  return setmetatable({ foundation = options.foundation, send = options.send,
    idFactory = options.idFactory, connected = options.connected,
    api = nil, pending = {}, grants = {}, offers = {}, prefixOutgoing = {}, serial = 0,
    frontierAdmission = options.frontierAdmission == true,
    durableArchive = options.durableArchive == true,
    admission = nil, admittedBase = nil, authorityRevision = nil,
    authorized = false, blocked = nil, membershipPending = false,
    rejoinRequired = false, archiveReady = false, archiveStarted = false,
    archiveIdentity = nil, archiveBatchesPending = nil }, M)
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
    writable = function()
      return (type(self.connected) ~= "function" or self.connected() == true)
        and self.authorized == true and self.blocked == nil
    end,
    request = function(_, actor, kind, subject, deliver)
      if type(self.connected) == "function" and self.connected() ~= true then
        return nil, "multiplayer transport is offline"
      end
      if self.blocked then return nil, self.blocked end
      if not self.authorized then return nil, "shared-world authority handshake is pending" end
      if self.membershipPending and kind ~= "campaign.membership.transition" then
        return nil, "canonical membership transition is pending"
      end
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
  if self.durableArchive and not self.archiveReady then
    if self.archiveStarted then return true end
    if type(self.api.archiveBatches) ~= "function" then
      return nil, "durable campaign archive export is unavailable"
    end
    -- One semantic event per line keeps every bootstrap message below the
    -- dedicated server's 64 KiB frame ceiling regardless of payload shape.
    local batches, archiveWhy = self.api.archiveBatches(1)
    if not batches then return nil, archiveWhy end
    self.archiveStarted = true
    self.archiveIdentity = { world = inventory.world,
      compatibility = inventory.compatibility, revision = frontier.revision }
    self.archiveBatchesPending = batches
    self.send(M.ARCHIVE_BEGIN, { inventory = inventory,
      frontier = frontier, batches = #batches })
    return true
  end
  self.admittedBase = nil
  self.authorityRevision = nil
  self.authorized, self.blocked, self.rejoinRequired = false, nil, false
  self.send(M.ADVERTISE, { inventory = inventory, frontier = frontier })
  return true
end

function M:onArchiveNeeded(raw)
  if not self.durableArchive or type(raw) ~= "table"
    or not self.archiveIdentity or raw.world ~= self.archiveIdentity.world
    or raw.compatibility ~= self.archiveIdentity.compatibility
    or raw.revision ~= self.archiveIdentity.revision
    or type(self.archiveBatchesPending) ~= "table" then
    return nil, "durable campaign archive request is invalid"
  end
  for _, envelope in ipairs(self.archiveBatchesPending) do
    self.send(M.ARCHIVE_BATCH, { envelope = envelope })
  end
  self.send(M.ARCHIVE_END, self.archiveIdentity)
  return true
end

function M:onArchiveReady(raw)
  if not self.durableArchive or type(raw) ~= "table"
    or not self.archiveIdentity or raw.world ~= self.archiveIdentity.world
    or raw.compatibility ~= self.archiveIdentity.compatibility
    or raw.revision ~= self.archiveIdentity.revision then
    return nil, "durable campaign archive acknowledgement is invalid"
  end
  self.archiveReady, self.archiveStarted = true, false
  self.archiveBatchesPending = nil
  return self:advertise()
end

function M:onReady(raw)
  if self.frontierAdmission then
    return nil, "campaign frontier acknowledgement is required"
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
  if self.foundation.apiVersion and self.foundation.apiVersion >= 4
    and type(self.foundation.ensureMembership) == "function" then
    if type(self.foundation.membership) == "function" then
      local membership, membershipWhy = self.foundation.membership()
      if not membership then
        self.authorized = false
        self.blocked = membershipWhy or "canonical membership is unavailable"
        return nil, self.blocked
      end
      if membership.state == "left" then
        self.authorized = false
        self.rejoinRequired = true
        self.blocked = "explicit rejoin consent is required"
        return true
      end
    end
    self.membershipPending = true
    local function complete(events, membershipWhy)
      self.membershipPending = false
      if not events then
        self.authorized = false
        self.blocked = membershipWhy or "canonical membership was refused"
      end
    end
    local membership, membershipWhy = self.foundation.ensureMembership(complete)
    if membership == "pending" then
      -- Membership is the only ordered write allowed through this transient
      -- window. Its issued grant remains valid after this gate closes; all
      -- unrelated content waits for the frontier produced by its commit.
      self.authorized = false
      return true
    end
    self.membershipPending = false
    if not membership then
      self.authorized = false
      self.blocked = membershipWhy or "canonical membership was refused"
      return nil, self.blocked
    end
  end
  return true
end

function M:membershipConsentRequired()
  return self.rejoinRequired == true
end

function M:rejoinMembership()
  if not self.rejoinRequired then
    return nil, "canonical rejoin consent is not pending"
  end
  if type(self.foundation.rejoinMembership) ~= "function" then
    return nil, "canonical rejoin is unavailable"
  end
  self.rejoinRequired = false
  self.membershipPending = true
  self.authorized, self.blocked = true, nil
  local function complete(events, why)
    self.membershipPending = false
    self.authorized = false
    if not events then
      self.blocked = why or "canonical rejoin was refused"
      self.rejoinRequired = self.blocked == "explicit rejoin consent is required"
    end
  end
  local result, why = self.foundation.rejoinMembership(complete)
  if result == "pending" then
    self.authorized = false
    return "pending"
  end
  self.membershipPending = false
  self.authorized = false
  if not result then
    self.blocked = why or "canonical rejoin was refused"
    return nil, self.blocked
  end
  return self:advertise()
end

function M:onUnavailable(reason)
  self.authorized = false
  local explanations = {
    duplicate_player = "this shared-world player is already connected",
    archive_required = "the server has not adopted this campaign archive",
    archive_incomplete = "the server requires the uncompacted campaign archive",
    archive_conflict = "the player save conflicts with the server campaign archive",
    archive_corrupt = "the server campaign archive is corrupt and must be repaired",
    archive_storage_failed = "the server could not durably store campaign history",
  }
  self.blocked = explanations[reason] or "shared-world authority is unavailable"
  failPending(self, self.blocked, true)
  return true
end

function M:active()
  if not self.api or type(self.api.status) ~= "function" then return false end
  local status = self.api.status()
  return type(status) == "table" and status.active == true
end

function M:status()
  return { connected = type(self.connected) ~= "function" or self.connected() == true,
    authorized = self.authorized == true, writable = self.authorized == true
      and self.blocked == nil
      and (type(self.connected) ~= "function" or self.connected() == true),
    blocked = self.blocked, membershipPending = self.membershipPending == true,
    rejoinRequired = self.rejoinRequired == true }
end

function M:certificationReceipt(context)
  if not self.api or type(self.api.certificationReceipt) ~= "function" then
    return nil, "shared-world certification receipt is unavailable"
  end
  return self.api.certificationReceipt(context)
end

function M:onInventory(from, inventory)
  if not self.api then return nil, "campaign transport is not attached" end
  local batches, why = self.api.missing(inventory)
  if not batches then
    if type(why) == "string" and why:find("closed%-prefix hydration") then
      local target = CampaignIdentity.identifier(from, 64)
      if not target or type(self.api.closedPrefixPackage) ~= "function" then
        return nil, "closed-prefix packaging is unavailable"
      end
      local package, packageWhy = self.api.closedPrefixPackage()
      if not package then return nil, packageWhy end
      local bounded = CampaignWire.worldClosedPackage(package)
      if bounded then
        self.send(M.PREFIX, { to = target, package = bounded })
        return "prefix_sent"
      end
      if type(self.api.closedPrefixFrames) ~= "function" then
        return nil, "closed-prefix package exceeds MMO transport boundary"
      end
      if self.prefixOutgoing[target] then return "prefix_streaming" end
      if tableCount(self.prefixOutgoing) >= M.MAX_PREFIX_STREAMS then
        return nil, "too many closed-prefix streams are pending"
      end
      local frames, framesWhy = self.api.closedPrefixFrames(
        CampaignWire.MAX_CLOSED_PACKAGE_WIRE)
      if not frames then return nil, framesWhy end
      local row = { frames = frames, index = 1 }
      self.prefixOutgoing[target] = row
      self.send(M.PREFIX_FRAME, { to = target, frame = frames[1] })
      return "prefix_streaming"
    end
    return nil, why
  end
  for _, envelope in ipairs(batches) do
    self.send(M.EVENTS, { to = from, envelope = envelope })
  end
  return #batches
end

function M:onPrefix(from, package)
  local source = CampaignIdentity.identifier(from, 64)
  if not source then return nil, "closed-prefix source is invalid" end
  if not self.api or type(self.api.adoptClosedPrefix) ~= "function" then
    return nil, "closed-prefix adoption is unavailable"
  end
  local ok, why = self.api.adoptClosedPrefix(package)
  if not ok then return nil, why end
  local advertised, advertiseWhy = self:advertise()
  if not advertised then return nil, advertiseWhy end
  return true
end

function M:onPrefixFrame(from, frame)
  local source = CampaignIdentity.identifier(from, 64)
  if not source or not self.api
    or type(self.api.receiveClosedPrefixFrame) ~= "function" then
    return nil, "closed-prefix frame adoption is unavailable"
  end
  local result, why = self.api.receiveClosedPrefixFrame(source, frame)
  if not result then return nil, why end
  self.send(M.PREFIX_FRAME_ACK, { to = source,
    transfer = frame.transfer, index = frame.index })
  if result == "pending" then return "pending" end
  local advertised, advertiseWhy = self:advertise()
  if not advertised then return nil, advertiseWhy end
  return true
end

function M:onPrefixFrameAck(from, acknowledgement)
  local target = CampaignIdentity.identifier(from, 64)
  local row = target and self.prefixOutgoing[target] or nil
  if not row or type(acknowledgement) ~= "table" then
    return nil, "closed-prefix frame acknowledgement is unexpected"
  end
  local current = row.frames[row.index]
  if acknowledgement.transfer ~= current.transfer
    or acknowledgement.index ~= current.index then
    return nil, "closed-prefix frame acknowledgement does not match"
  end
  row.index = row.index + 1
  if row.index > #row.frames then
    self.prefixOutgoing[target] = nil
    return true
  end
  self.send(M.PREFIX_FRAME, { to = target, frame = row.frames[row.index] })
  return "pending"
end

function M:onPeerUnavailable(raw)
  local peer = CampaignIdentity.identifier(raw, 64)
  if not peer then return nil, "campaign peer identity is invalid" end
  self.prefixOutgoing[peer] = nil
  if self.api and type(self.api.resetClosedPrefixFrames) == "function" then
    self.api.resetClosedPrefixFrames(peer)
  end
  return true
end

function M:onEvents(envelope)
  if not self.api then return nil, "campaign transport is not attached" end
  local accepted, why = self.api.receive(envelope)
  if accepted and accepted > 0 and self.frontierAdmission then self:advertise() end
  return accepted, why
end

function M:invite(to)
  local delivered = false
  local function sendInvitation(invitation, why)
    if delivered then return end
    delivered = true
    if not invitation then return nil, why end
    self.send(M.INVITE, { to = to, invitation = invitation })
    return true
  end
  local invitation, why = self.foundation.invitation(sendInvitation)
  if invitation == "pending" then return "pending" end
  if not invitation then return nil, why end
  return sendInvitation(invitation)
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
  self.prefixOutgoing = {}
  if self.api and type(self.api.resetClosedPrefixFrames) == "function" then
    pcall(self.api.resetClosedPrefixFrames)
  end
  if self.admission then self.admission:reset(reason) end
  self.admittedBase = nil
  self.authorityRevision = nil
  self.authorized, self.blocked = false, nil
  self.membershipPending = false
  self.rejoinRequired = false
  self.archiveReady, self.archiveStarted, self.archiveIdentity = false, false, nil
  self.archiveBatchesPending = nil
  return true
end

return M
