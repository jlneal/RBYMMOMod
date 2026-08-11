-- Pure bridge-side lifecycle for campaign_state's authenticated frontier gate.
-- It sends no packets and owns no campaign meaning. A protocol adapter uses the
-- returned acknowledgement row, waits for an exact hub echo, and revalidates
-- the bound base immediately before accepting a sequence grant.

local need = ...
local CampaignIdentity = need("CampaignIdentity")

local M = {}
M.__index = M

local function base(raw)
  if type(raw) ~= "table" or raw.version ~= 1 then return nil end
  local world = CampaignIdentity.identifier(raw.world, 64)
  local compatibility = CampaignIdentity.identifier(raw.compatibility, 96)
  local position = tonumber(raw.position)
  local digest = type(raw.baseDigest) == "string"
    and raw.baseDigest:match("^[0-9a-f]+$") and #raw.baseDigest == 16
    and raw.baseDigest or nil
  local authorityRevision = type(raw.authorityRevision) == "string"
    and raw.authorityRevision:match("^[0-9a-f]+$")
    and #raw.authorityRevision == 16 and raw.authorityRevision or nil
  local replicaRevision = type(raw.replicaRevision) == "string"
    and raw.replicaRevision:match("^[0-9a-f]+$")
    and #raw.replicaRevision == 16 and raw.replicaRevision or nil
  if not (world and compatibility and position and position == math.floor(position)
    and position >= 1 and position <= 9007199254740991
    and digest and authorityRevision and replicaRevision) then
    return nil
  end
  return { version = 1, world = world, compatibility = compatibility,
    position = position, baseDigest = digest,
    authorityRevision = authorityRevision, replicaRevision = replicaRevision }
end

local function sameBase(left, right)
  return left and right and left.version == right.version
    and left.world == right.world and left.compatibility == right.compatibility
    and left.position == right.position and left.baseDigest == right.baseDigest
    and left.authorityRevision == right.authorityRevision
    and left.replicaRevision == right.replicaRevision
end

function M.new(api)
  if type(api) ~= "table" or type(api.frontier) ~= "function"
    or type(api.admission) ~= "function"
    or type(api.validateGrantBase) ~= "function" then
    return nil, "frontier admission API is required"
  end
  return setmetatable({ api = api, state = "detached", authority = nil,
    expected = nil, writableBase = nil, reason = nil }, M)
end

function M:observe(authority)
  self.authority, self.expected, self.writableBase = nil, nil, nil
  local assessed, why = self.api.admission(authority)
  if not assessed then
    self.state, self.reason = "frozen", tostring(why or "frontier refused")
    return nil, self.reason
  end
  self.state, self.reason, self.authority = assessed.state, assessed.reason, authority
  if assessed.state ~= "matched" then
    return { state = assessed.state, reason = assessed.reason }
  end
  local writable, ackWhy = self.api.admission(authority,
    assessed.replica and assessed.replica.revision)
  if not writable or writable.state ~= "writable" then
    self.state, self.reason = "frozen", tostring(ackWhy or "frontier acknowledgement failed")
    return nil, self.reason
  end
  local cleanBase = base(writable.grantBase)
  local frontier, frontierWhy = self.api.frontier()
  if not cleanBase or type(frontier) ~= "table" then
    self.state, self.reason = "frozen",
      tostring(frontierWhy or "frontier acknowledgement artifact is invalid")
    return nil, self.reason
  end
  self.state = "acknowledging"
  self.expected = { authorityRevision = cleanBase.authorityRevision,
    replicaRevision = cleanBase.replicaRevision, grantBase = cleanBase }
  return { state = self.state, frontier = frontier,
    authorityRevision = cleanBase.authorityRevision,
    replicaRevision = cleanBase.replicaRevision, grantBase = cleanBase }
end

function M:confirm(raw)
  if self.state ~= "acknowledging" or not self.expected or type(raw) ~= "table" then
    return nil, "frontier acknowledgement is not pending"
  end
  local echoed = base(raw.grantBase)
  if raw.authorityRevision ~= self.expected.authorityRevision
    or raw.replicaRevision ~= self.expected.replicaRevision
    or not sameBase(echoed, self.expected.grantBase) then
    self.state, self.reason, self.expected = "frozen",
      "frontier acknowledgement echo mismatch", nil
    return nil, self.reason
  end
  local valid, why = self.api.validateGrantBase(echoed, self.authority)
  if not valid then
    self.state, self.reason, self.expected = "catching_up", tostring(why), nil
    return nil, self.reason
  end
  self.state, self.reason, self.writableBase, self.expected =
    "writable", nil, echoed, nil
  return true
end

function M:validate(raw)
  if self.state ~= "writable" or not self.writableBase then
    return nil, "canonical frontier is not writable"
  end
  local candidate = base(raw)
  if not sameBase(candidate, self.writableBase) then
    self.state, self.reason, self.writableBase = "frozen",
      "sequence grant base does not match admitted frontier", nil
    return nil, self.reason
  end
  local valid, why = self.api.validateGrantBase(candidate, self.authority)
  if not valid then
    self.state, self.reason, self.writableBase = "catching_up", tostring(why), nil
    return nil, self.reason
  end
  return true
end

function M:reset(reason)
  self.state, self.reason = "detached", reason
  self.authority, self.expected, self.writableBase = nil, nil, nil
  return true
end

function M:status()
  return { state = self.state, reason = self.reason,
    authorityRevision = self.writableBase and self.writableBase.authorityRevision or nil,
    replicaRevision = self.writableBase and self.writableBase.replicaRevision or nil }
end

M.normalizeBase = base
M.sameBase = sameBase

return M
