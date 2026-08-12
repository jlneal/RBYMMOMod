-- Optional semantic requirements attached by content adapters to one battle.
-- The MMO remains transport: it validates and executes only capabilities it
-- explicitly advertises, and ordinary contexts retain the v1 shape.

local need = ...
local Identity = need("CampaignIdentity")
local M = {}

M.CAPABILITIES = {
  "automatic-trainer-second-slot",
  "late-trainer-join-through-active-battle",
  "trainer-flee-policy",
  "paired-opponent-party",
  "completed-helper-existing-opponent",
}

local supported = {}
for _, id in ipairs(M.CAPABILITIES) do supported[id] = true end

local function requirements(raw)
  if raw == nil then return nil end
  if type(raw) ~= "table" then return nil, "battle requirements are invalid" end
  local allowed = { joinPolicy = true, enrollmentCutoff = true,
    fleeAllowed = true, opponentPolicy = true, opponent = true }
  for key in pairs(raw) do
    if not allowed[key] then return nil, "battle requirement is unsupported" end
  end
  local out = {}
  if raw.enrollmentCutoff ~= nil then
    if raw.enrollmentCutoff ~= "resolution"
      or not supported["late-trainer-join-through-active-battle"] then
      return nil, "trainer enrollment cutoff is unsupported"
    end
    out.enrollmentCutoff = raw.enrollmentCutoff
  end
  if raw.joinPolicy ~= nil then
    if raw.joinPolicy ~= "automatic-second-slot"
      or not supported["automatic-trainer-second-slot"] then
      return nil, "trainer join policy is unsupported"
    end
    out.joinPolicy = raw.joinPolicy
  end
  if raw.fleeAllowed ~= nil then
    if type(raw.fleeAllowed) ~= "boolean"
      or not supported["trainer-flee-policy"] then
      return nil, "trainer flee policy is unsupported"
    end
    out.fleeAllowed = raw.fleeAllowed
  end
  if raw.opponentPolicy ~= nil or raw.opponent ~= nil then
    local opponent = raw.opponent
    if raw.opponentPolicy == "existing-second-party-member" and opponent == nil
      and supported["completed-helper-existing-opponent"] then
      out.opponentPolicy = raw.opponentPolicy
    elseif raw.opponentPolicy ~= "paired-rival" or type(opponent) ~= "table"
      or type(opponent.trainerClass) ~= "string"
      or not opponent.trainerClass:match("^[%w_%-]+$")
      or #opponent.trainerClass > 40
      or type(opponent.partyIndex) ~= "number" or opponent.partyIndex < 1
      or opponent.partyIndex > 255 or opponent.partyIndex ~= math.floor(opponent.partyIndex)
      or not Identity.identifier(opponent.owner, 64)
      or not Identity.identifier(opponent.rival, 96) then
      return nil, "paired trainer opponent is unsupported"
    else
      out.opponentPolicy = "paired-rival"
      out.opponent = { trainerClass = opponent.trainerClass,
        partyIndex = opponent.partyIndex, owner = opponent.owner,
        rival = opponent.rival }
    end
  end
  return next(out) and out or nil
end

function M.normalize(raw)
  local occurrence = type(raw) == "table"
    and Identity.identifier(raw.occurrence, 96) or nil
  local definition = type(raw) == "table" and raw.definition or nil
  if not occurrence or type(definition) ~= "string" or #definition ~= 16
    or not definition:match("^[0-9a-f]+$") then
    return nil, "battle context identity is invalid"
  end
  local policy, why = requirements(raw.requirements)
  if raw.requirements ~= nil and not policy then return nil, why end
  return { occurrence = occurrence, definition = definition,
    requirements = policy }
end

function M.same(left, right)
  if not (left and right) or left.occurrence ~= right.occurrence
    or left.definition ~= right.definition then return false end
  local a, b = left.requirements or {}, right.requirements or {}
  return a.joinPolicy == b.joinPolicy
    and a.enrollmentCutoff == b.enrollmentCutoff
    and a.fleeAllowed == b.fleeAllowed
    and a.opponentPolicy == b.opponentPolicy
    and ((a.opponent == nil and b.opponent == nil)
      or (a.opponent and b.opponent
        and a.opponent.trainerClass == b.opponent.trainerClass
        and a.opponent.partyIndex == b.opponent.partyIndex
        and a.opponent.owner == b.opponent.owner
        and a.opponent.rival == b.opponent.rival))
end

function M.capabilities()
  local out = {}
  for index, id in ipairs(M.CAPABILITIES) do out[index] = id end
  return out
end

return M
