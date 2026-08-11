local root = "src/"
local cache = {}
local function need(name)
  if cache[name] then return cache[name] end
  local chunk, why = loadfile(root .. name .. ".lua")
  assert(chunk, why)
  local value = chunk(need, {})
  cache[name] = value
  return value
end
local Bridge = need("CampaignStateBridge")
local passed = 0
local function check(value, message) assert(value, message); passed = passed + 1 end
local function eq(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": expected "
    .. tostring(expected) .. ", got " .. tostring(actual))
  passed = passed + 1
end

local sent, attached, acceptedInvitation = {}, nil, nil
local foundation = {
  apiVersion = 3,
  registerTransport = function(id, transport)
    eq(id, "rby-mmo", "bridge registers only as a transport")
    attached = transport
    transport.attach({
      inventory = function() return { signed = "inventory" } end,
      batch = function(events)
        eq(events[1].kind, "unique", "completed transaction reaches signer")
        return { signed = "committed-events" }
      end,
      missing = function(remote)
        eq(remote.signed, "remote", "opaque inventory reaches framework unchanged")
        return { { signed = "events" } }
      end,
      receive = function(envelope)
        eq(envelope.signed, "events", "opaque batch reaches framework unchanged")
        return 2
      end,
      status = function()
        return { active = true, worldId = "world-1", playerId = "ann" }
      end,
    })
    return true
  end,
  invitation = function() return { signed = "invitation" } end,
  acceptInvitation = function(value) acceptedInvitation = value; return true end,
}
eq(Bridge.new({ foundation = { apiVersion = 1,
  registerTransport = function() return true end }, send = function() end }), nil,
  "bridge refuses a campaign facade older than its transport contract")
local bridge = assert(Bridge.new({ foundation = foundation,
  send = function(kind, payload) sent[#sent + 1] = { kind = kind, payload = payload } end }))
check(bridge:install(), "bridge attaches through campaign_state public API")
check(attached and attached.authority, "bridge supplies an authority service")
check(type(attached.lifecycle) == "function",
  "bridge exposes checkpoint/save lifecycle reset to the framework")
check(bridge:advertise(), "bridge advertises signed inventory")
eq(sent[#sent].kind, Bridge.ADVERTISE, "advertisement uses dedicated wire kind")
local early, earlyWhy = attached.authority:request("ann", "unique", "articuno")
eq(early, nil, "writes wait for the hub's authority acknowledgement")
check(tostring(earlyWhy):find("handshake") ~= nil,
  "a pre-acknowledgement refusal names the pending handshake")
check(bridge:onReady({ world = "world-1", player = "ann" }),
  "matching hub acknowledgement admits this save identity")
eq(bridge:onInventory("peer", { signed = "remote" }), 1,
  "framework plans missing signed batches")
eq(sent[#sent].payload.to, "peer", "missing batch is directed to its peer")
eq(bridge:onEvents({ signed = "events" }), 2,
  "framework owns acceptance of opaque event envelope")
check(bridge:invite("peer"), "bridge relays signed invitation")
eq(sent[#sent].kind, Bridge.INVITE, "invitation uses dedicated wire kind")
check(bridge:accept({ signed = "accepted" }), "bridge delegates enrollment")
eq(acceptedInvitation.signed, "accepted", "bridge does not reinterpret invitation")

local offersAccepted = true
for index = 1, Bridge.MAX_OFFERS do
  offersAccepted = offersAccepted and bridge:onInvitation(
    "inviter-" .. tostring(index), { signed = "offer" }) == true
end
check(offersAccepted, "bridge stages a bounded invitation inbox")
local extraOffer, extraOfferWhy = bridge:onInvitation("inviter-overflow",
  { signed = "offer" })
eq(extraOffer, nil, "bridge refuses an unbounded invitation inbox")
check(tostring(extraOfferWhy):find("too many") ~= nil,
  "invitation inbox capacity refusal is explicit")

local pendingFailure, allQueued = nil, true
for index = 1, Bridge.MAX_OUTSTANDING do
  local result = attached.authority:request("ann", "unique",
    "queued-" .. tostring(index), function(_, why) pendingFailure = why end)
  allQueued = allQueued and result == "pending"
end
check(allQueued, "bridge admits reservations only up to its bounded capacity")
local overflow, overflowWhy = attached.authority:request("ann", "unique", "overflow")
eq(overflow, nil, "bridge refuses an unbounded reservation queue")
check(tostring(overflowWhy):find("too many") ~= nil,
  "reservation capacity refusal is explicit")
check(bridge:onUnavailable("authority_lost"),
  "authority loss drains outstanding reservations")
check(tostring(pendingFailure):find("unavailable") ~= nil,
  "pending adapters receive the authority-loss reason")
eq(next(bridge.pending), nil, "authority loss leaves no pending request leak")
check(bridge:onReady({ world = "world-1", player = "ann" }),
  "authority can be acknowledged again after queue cleanup")

local delivered
eq(attached.authority:request("ann", "unique", "articuno",
  function(grant, why) delivered = grant or why end), "pending",
  "network sequence request is asynchronous")
eq(sent[#sent].kind, Bridge.SEQUENCE_REQUEST,
  "authority request is sent to the coordinator")
local request = sent[#sent].payload.request
local grant = assert(bridge:onGrant({ request = request, grant = "grant-1",
  world = "world-1", position = 7 }))
eq(delivered.grant, "grant-1", "matching asynchronous grant reaches adapter")
check(attached.authority:permits("grant-1", "ann", "unique", "articuno"),
  "bridge verifies grant subject and actor")
eq(attached.authority:commit("grant-1", { { kind = "unique" } }), 7,
  "committing transition releases exact canonical position")
eq(sent[#sent].kind, Bridge.SEQUENCE_COMMIT,
  "coordinator is told that position committed")
eq(sent[#sent - 1].kind, Bridge.EVENTS,
  "signed transaction is relayed before its position is released")

local checkpointFailure
assert(attached.authority:request("ann", "unique", "zapdos",
  function(_, why) checkpointFailure = why end))
check(attached.lifecycle("checkpoint.restored", true),
  "successful checkpoint lifecycle resets and re-advertises")
check(tostring(checkpointFailure):find("checkpoint.restored", 1, true),
  "checkpoint reset drains old pending authority callbacks")
eq(sent[#sent].kind, Bridge.ADVERTISE,
  "restored archive publishes a fresh signed inventory")
eq(bridge.authorized, false,
  "restored replica must repeat authority admission")

-- Protocol 19 adds an authenticated frontier/acknowledgement gate without
-- changing the protocol-18 bridge behavior proved above.
local A, R, D = string.rep("a", 16), string.rep("b", 16), string.rep("c", 16)
local authorityFrontier = { version = 1, world = "world-19",
  compatibility = "campaign-state.4.frontier", timelineHead = 3,
  canonicalDigest = D, heads = { ann = 4 }, revision = A,
  tag = string.rep("d", 64) }
local replicaFrontier = { version = 1, world = "world-19",
  compatibility = "campaign-state.4.frontier", timelineHead = 3,
  canonicalDigest = D, heads = { ann = 4 }, revision = R,
  tag = string.rep("e", 64) }
local grantBase = { version = 1, world = "world-19",
  compatibility = "campaign-state.4.frontier", position = 4,
  baseDigest = D, authorityRevision = A, replicaRevision = R }
local sent19, attached19, receiveCount = {}, nil, 0
local foundation19 = {
  apiVersion = 3,
  registerTransport = function(_, transport)
    attached19 = transport
    transport.attach({
      inventory = function() return { signed = "inventory-19" } end,
      frontier = function() return replicaFrontier end,
      admission = function(authority, revision)
        eq(authority, authorityFrontier,
          "frontier authority remains opaque to the MMO bridge")
        if revision == nil then
          return { state = "matched", replica = { revision = R } }
        end
        if revision ~= R then return nil, "stale acknowledgement" end
        return { state = "writable", grantBase = grantBase }
      end,
      validateGrantBase = function(base, authority)
        return base.position == 4 and base.baseDigest == D
          and authority == authorityFrontier
      end,
      batch = function() return { signed = "events-19" } end,
      missing = function() return {} end,
      receive = function()
        receiveCount = receiveCount + 1
        return 1
      end,
      status = function()
        return { active = true, worldId = "world-19", playerId = "ann" }
      end,
    })
    return true
  end,
  invitation = function() return { signed = "invitation-19" } end,
  acceptInvitation = function() return true end,
}
local bridge19 = assert(Bridge.new({ foundation = foundation19,
  frontierAdmission = true,
  send = function(kind, payload)
    sent19[#sent19 + 1] = { kind = kind, payload = payload }
  end }))
check(bridge19:install(), "protocol-19 bridge installs against API 3")
check(bridge19:advertise(), "protocol-19 advertisement is produced")
eq(sent19[#sent19].payload.frontier, replicaFrontier,
  "protocol-19 advertisement carries the signed local frontier")
eq(bridge19:onReady({ world = "world-19", player = "ann" }), nil,
  "protocol-18 ready cannot bypass frontier admission")
local acknowledging = assert(bridge19:onFrontier(authorityFrontier))
eq(acknowledging.state, "acknowledging",
  "matching authority frontier produces a bound acknowledgement")
eq(sent19[#sent19].kind, Bridge.FRONTIER_ACK,
  "frontier acknowledgement uses its protocol-19 wire kind")
local echo = sent19[#sent19].payload.admission
check(bridge19:onFrontierReady(echo),
  "exact hub echo makes protocol-19 authority writable")
local delivered19
eq(attached19.authority:request("ann", "unique", "articuno",
  function(grant, why) delivered19 = grant or why end), "pending",
  "frontier-admitted authority request remains asynchronous")
eq(sent19[#sent19].payload.base.position, 4,
  "sequence request carries its admitted canonical grant base")
local request19 = sent19[#sent19].payload.request
check(bridge19:onGrant({ request = request19, grant = "grant-19",
  world = "world-19", position = 4, base = grantBase }),
  "exact-base sequence grant passes immediate revalidation")
eq(delivered19.grant, "grant-19",
  "validated protocol-19 grant reaches the content adapter")
eq(bridge19:onEvents({ signed = "remote-19" }), 1,
  "protocol-19 bridge accepts a framework-verified remote batch")
eq(receiveCount, 1, "remote batch is delivered exactly once")
eq(sent19[#sent19].kind, Bridge.ADVERTISE,
  "remote history change immediately advertises a fresh frontier")
local cancelled19 = sent19[#sent19 - 1]
eq(cancelled19.kind, Bridge.SEQUENCE_CANCEL,
  "a remote frontier change cancels a grant bound to the old base")
eq(cancelled19.payload.grant, "grant-19",
  "frontier invalidation cancels the exact stale grant")
eq(attached19.authority:commit("grant-19", {}), nil,
  "a stale grant cannot commit after the frontier changes")

eq(assert(bridge19:onFrontier(authorityFrontier)).state, "acknowledging",
  "caught-up replica returns to acknowledgement")
local echoAgain = sent19[#sent19].payload.admission
check(bridge19:onFrontierReady(echoAgain),
  "frontier can be re-admitted after remote catch-up")
assert(attached19.authority:request("ann", "unique", "zapdos"))
local requestAfterCatchup = sent19[#sent19].payload.request
check(bridge19:onGrant({ request = requestAfterCatchup, grant = "grant-reset-19",
  world = "world-19", position = 4, base = grantBase }),
  "freshly admitted grant reaches the bridge before a save switch")
check(attached19.lifecycle("save.switched", true),
  "save lifecycle resets protocol-19 admission and advertises the reopened archive")
eq(sent19[#sent19 - 1].kind, Bridge.SEQUENCE_CANCEL,
  "save lifecycle explicitly cancels its already issued old-save grant")
eq(attached19.authority:commit("grant-reset-19", {}), nil,
  "old-save grant cannot commit after lifecycle reset")
eq(bridge19.authorized, false,
  "reopened save must repeat canonical frontier admission")

print(("campaign state MMO bridge: %d assertions passed"):format(passed))
