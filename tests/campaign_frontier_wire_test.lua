local cache = {}
local function need(name)
  if cache[name] then return cache[name] end
  cache[name] = assert(loadfile("src/" .. name .. ".lua"))(need, {})
  return cache[name]
end
local Wire = need("CampaignWire")
local passed = 0
local function check(value, message) assert(value, message); passed = passed + 1 end
local function eq(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": expected "
    .. tostring(expected) .. ", got " .. tostring(actual))
  passed = passed + 1
end
local A, R, D, T = string.rep("a", 16), string.rep("b", 16),
  string.rep("c", 16), string.rep("d", 64)
local function frontier()
  return { version = 1, world = "shared-kanto",
    compatibility = "campaign-state.4.proof", timelineHead = 3,
    canonicalDigest = D, heads = { ann = 7, bob = 2 },
    revision = R, tag = T }
end
local function base()
  return { version = 1, world = "shared-kanto",
    compatibility = "campaign-state.4.proof", position = 4,
    baseDigest = D, authorityRevision = A, replicaRevision = R }
end

local cleanFrontier = assert(Wire.worldFrontier(frontier()))
eq(cleanFrontier.timelineHead, 3, "Lua accepts a bounded signed frontier")
eq(cleanFrontier.heads.ann, 7, "Lua rebuilds actor heads")
local cleanBase = assert(Wire.worldGrantBase(base()))
eq(cleanBase.position, 4, "Lua accepts the exact next-position base")
local admission = assert(Wire.worldFrontierAdmission({ frontier = frontier(),
  authorityRevision = A, replicaRevision = R, grantBase = base() }))
eq(admission.replicaRevision, R, "Lua accepts an internally bound acknowledgement")

local bad = frontier(); bad.version = 2
eq(Wire.worldFrontier(bad), nil, "Lua refuses an unknown frontier version")
bad = frontier(); bad.timelineHead = 4097
eq(Wire.worldFrontier(bad), nil, "Lua bounds canonical head by archive capacity")
bad = frontier(); bad.timelineHead = "3"
eq(Wire.worldFrontier(bad), nil, "Lua refuses a numeric-string canonical head")
bad = frontier(); bad.timelineHead = 3.5
eq(Wire.worldFrontier(bad), nil, "Lua refuses a fractional canonical head")
bad = frontier(); bad.revision = string.rep("g", 16)
eq(Wire.worldFrontier(bad), nil, "Lua refuses a non-hex revision")
bad = frontier(); bad.tag = string.rep("a", 63)
eq(Wire.worldFrontier(bad), nil, "Lua requires a complete authentication tag")
bad = frontier(); bad.heads.eve = 1 / 0
eq(Wire.worldFrontier(bad), nil, "Lua refuses non-finite actor heads")
bad = frontier(); bad.heads.eve = "1"
eq(Wire.worldFrontier(bad), nil, "Lua refuses a numeric-string actor head")
bad = frontier(); bad.heads = {}
for index = 1, 65 do bad.heads["actor" .. index] = index end
eq(Wire.worldFrontier(bad), nil, "Lua bounds frontier actors")

bad = base(); bad.position = 0
eq(Wire.worldGrantBase(bad), nil, "Lua refuses a zero grant position")
bad = base(); bad.position = 4.5
eq(Wire.worldGrantBase(bad), nil, "Lua refuses a fractional grant position")
bad = base(); bad.baseDigest = string.rep("0", 15)
eq(Wire.worldGrantBase(bad), nil, "Lua requires a complete base digest")
bad = base(); bad.compatibility = "bad compatibility"
eq(Wire.worldGrantBase(bad), nil, "Lua refuses an invalid compatibility identity")

local row = { frontier = frontier(), authorityRevision = A,
  replicaRevision = R, grantBase = base() }
row.authorityRevision = string.rep("e", 16)
eq(Wire.worldFrontierAdmission(row), nil,
  "Lua refuses an authority revision not bound into the base")
row = { frontier = frontier(), authorityRevision = A,
  replicaRevision = string.rep("e", 16), grantBase = base() }
eq(Wire.worldFrontierAdmission(row), nil,
  "Lua refuses a replica revision echo mismatch")
row = { frontier = frontier(), authorityRevision = A,
  replicaRevision = R, grantBase = base() }
row.grantBase.position = 5
eq(Wire.worldFrontierAdmission(row), nil,
  "Lua refuses a base that skips the exact next position")
row = { frontier = frontier(), authorityRevision = A,
  replicaRevision = R, grantBase = base() }
row.grantBase.world = "other-world"
eq(Wire.worldFrontierAdmission(row), nil,
  "Lua refuses cross-world acknowledgement binding")
check(Wire.worldInventory({}) == nil,
  "protocol-18 sanitizers retain their existing refusal behavior")
local grant = { request = "request-1", grant = "grant-1",
  world = "shared-kanto", position = 4, base = base() }
eq(assert(Wire.worldSequenceGrant(grant, true)).base.baseDigest, D,
  "protocol-19 sequence grant retains its admitted base")
local missingBase = { request = grant.request, grant = grant.grant,
  world = grant.world, position = grant.position }
eq(Wire.worldSequenceGrant(missingBase, true), nil,
  "protocol-19 sequence grant requires its admitted base")
check(Wire.worldSequenceGrant(missingBase) ~= nil,
  "protocol-18 sequence grant remains backward compatible")

print(("campaign frontier wire: %d assertions passed"):format(passed))
