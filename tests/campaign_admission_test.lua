local root = "src/"
local cache = {}
local function need(name)
  if cache[name] then return cache[name] end
  local value = assert(loadfile(root .. name .. ".lua"))(need, {})
  cache[name] = value
  return value
end
local Admission = need("CampaignAdmission")
local passed = 0
local function check(value, message) assert(value, message); passed = passed + 1 end
local function eq(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": expected "
    .. tostring(expected) .. ", got " .. tostring(actual))
  passed = passed + 1
end

local revisionA, revisionR = "aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"
local expectedBase = { version = 1, world = "world-1", compatibility = "compat-1",
  position = 8, baseDigest = "cccccccccccccccc",
  authorityRevision = revisionA, replicaRevision = revisionR }
local localRevision, validation = revisionR, true
local api = {
  frontier = function() return { signed = "local-frontier", revision = localRevision } end,
  admission = function(authority, revision)
    if authority.tampered then return nil, "authentication failed" end
    if authority.behind then return { state = "catching_up" } end
    if revision == nil then
      return { state = "matched", replica = { revision = localRevision } }
    end
    if revision ~= localRevision then return nil, "acknowledgement is stale" end
    return { state = "writable", grantBase = expectedBase }
  end,
  validateGrantBase = function(candidate)
    if not validation or candidate.replicaRevision ~= localRevision then
      return nil, "catching_up"
    end
    return true
  end,
}

local gate = assert(Admission.new(api))
eq(gate:status().state, "detached", "admission begins detached")
eq(assert(gate:observe({ behind = true })).state, "catching_up",
  "behind replica remains read-only while history catches up")
local ack = assert(gate:observe({ signed = "authority" }))
eq(ack.state, "acknowledging", "matched frontier produces an acknowledgement")
eq(ack.frontier.signed, "local-frontier",
  "acknowledgement carries a freshly signed local frontier")
eq(ack.grantBase.position, 8, "acknowledgement binds the next position")
eq(gate:validate(ack.grantBase), nil,
  "grant cannot arrive before the hub confirms the acknowledgement")

local badEcho, badEchoWhy = gate:confirm({ authorityRevision = revisionA,
  replicaRevision = revisionR, grantBase = {
    version = 1, world = "world-1", compatibility = "compat-1", position = 9,
    baseDigest = "cccccccccccccccc", authorityRevision = revisionA,
    replicaRevision = revisionR,
  } })
eq(badEcho, nil, "changed acknowledgement echo is refused")
check(tostring(badEchoWhy):find("mismatch", 1, true) ~= nil,
  "changed acknowledgement echo is attributed")
eq(gate:status().state, "frozen", "echo mismatch freezes grant admission")

ack = assert(gate:observe({ signed = "authority" }))
check(gate:confirm(ack), "exact hub echo makes the frontier writable")
eq(gate:status().state, "writable", "confirmed frontier reports writable")
check(gate:validate(ack.grantBase), "exact fresh grant base validates")
local forged = {}
for key, value in pairs(ack.grantBase) do forged[key] = value end
forged.baseDigest = "dddddddddddddddd"
local forgedOk, forgedWhy = gate:validate(forged)
eq(forgedOk, nil, "grant from another canonical base is refused")
check(tostring(forgedWhy):find("does not match", 1, true) ~= nil,
  "foreign grant base refusal is explicit")
eq(gate:status().state, "frozen", "foreign grant base freezes admission")

ack = assert(gate:observe({ signed = "authority" }))
check(gate:confirm(ack), "frontier can be acknowledged again")
localRevision, validation = "eeeeeeeeeeeeeeee", false
local staleOk, staleWhy = gate:validate(ack.grantBase)
eq(staleOk, nil, "local history change revokes a confirmed grant base")
check(tostring(staleWhy):find("catching_up", 1, true) ~= nil,
  "revoked base returns to catch-up")
eq(gate:status().state, "catching_up", "revocation state is visible")

local tampered, tamperedWhy = gate:observe({ tampered = true })
eq(tampered, nil, "unauthenticated authority frontier is refused")
check(tostring(tamperedWhy):find("authentication", 1, true) ~= nil,
  "authority authentication refusal is retained")
eq(gate:status().state, "frozen", "bad authority artifact freezes admission")
check(gate:reset("disconnect"), "disconnect resets the admission lifecycle")
eq(gate:status().state, "detached", "reset removes writability")

print(("campaign bridge admission: %d assertions passed"):format(passed))
