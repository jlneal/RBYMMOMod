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
      certificationReceipt = function(context)
        return { signed = "live-receipt", phase = context.phase }
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
check(bridge:status().connected and not bridge:status().writable,
  "transport presence alone does not claim campaign writability")
check(type(attached.lifecycle) == "function",
  "bridge exposes checkpoint/save lifecycle reset to the framework")
check(bridge:advertise(), "bridge advertises signed inventory")
eq(sent[#sent].kind, Bridge.ADVERTISE, "advertisement uses dedicated wire kind")
local liveReceipt = assert(bridge:certificationReceipt({ phase = "after-reload" }))
eq(liveReceipt.signed, "live-receipt",
  "bridge exposes the transport-scoped live certification boundary")
eq(liveReceipt.phase, "after-reload",
  "bridge leaves live evidence context to Campaign State")
local early, earlyWhy = attached.authority:request("ann", "unique", "articuno")
eq(early, nil, "writes wait for the hub's authority acknowledgement")
check(tostring(earlyWhy):find("handshake") ~= nil,
  "a pre-acknowledgement refusal names the pending handshake")
check(bridge:onReady({ world = "world-1", player = "ann" }),
  "matching hub acknowledgement admits this save identity")
check(bridge:status().authorized and bridge:status().writable,
  "authority diagnostics become writable only after admission")
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
check(not bridge:status().writable and bridge:status().blocked ~= nil,
  "authority loss is immediately visible to shared campaign policy")
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
check(bridge19:status().writable,
  "frontier admission is reflected by the public bridge status")
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

-- Protocol 29 makes durable server adoption precede ordinary admission.
local sent29, attached29 = {}, nil
local binding29
local foundation29 = {
  apiVersion = 4,
  registerTransport = function(_, transport)
    attached29 = transport
    transport.attach({
      inventory = function() return { schema = 1, world = "world-29",
        compatibility = "campaign-state.4.durable", player = "ann",
        timelineHead = 0, heads = {}, tag = string.rep("a", 64) } end,
      frontier = function() return { version = 1, world = "world-29",
        compatibility = "campaign-state.4.durable", timelineHead = 0,
        canonicalDigest = string.rep("b", 16), heads = {},
        revision = string.rep("c", 16), tag = string.rep("d", 64) } end,
      archiveBatches = function() return {} end,
      authorityBinding = function(authority)
        if authority and binding29 and authority ~= binding29 then return nil end
        binding29 = binding29 or authority
        return binding29
      end,
      admission = function() return { state = "matched",
        replica = { revision = string.rep("c", 16) } } end,
      validateGrantBase = function() return true end,
      batch = function() return {} end, missing = function() return {} end,
      receive = function() return 0 end,
      status = function() return { active = true, worldId = "world-29",
        playerId = "ann" } end,
    })
    return true
  end,
}
local bridge29 = assert(Bridge.new({ foundation = foundation29,
  frontierAdmission = true, durableArchive = true,
  send = function(kind, payload)
    sent29[#sent29 + 1] = { kind = kind, payload = payload }
  end }))
assert(bridge29:install())
check(bridge29:advertise(), "durable bridge starts server archive bootstrap")
eq(sent29[1].kind, Bridge.ARCHIVE_BEGIN,
  "archive manifest precedes canonical admission")
eq(#sent29, 1, "ordinary advertisement waits for server archive disposition")
check(bridge29:onArchiveNeeded({ world = "world-29",
  compatibility = "campaign-state.4.durable", revision = string.rep("c", 16),
  authority = "campaign-authority-one" }),
  "empty server requests the participant's authenticated source archive")
eq(sent29[#sent29].kind, Bridge.ARCHIVE_END,
  "empty archive still has an explicit completion boundary")
check(bridge29:onArchiveReady({ world = "world-29",
  compatibility = "campaign-state.4.durable", revision = string.rep("c", 16),
  authority = "campaign-authority-one" }),
  "exact server archive acknowledgement resumes admission")
eq(sent29[#sent29].kind, Bridge.ADVERTISE,
  "admission advertisement follows durable archive adoption")

-- Protocol 23 closes the one gap ordinary missing-batch exchange cannot cross;
-- protocol 24 adds acknowledged framing above the one-message boundary.
local sent23, attached23, adopted23 = {}, nil, nil
local package23 = { schema = 1, world = "world-23",
  compatibility = "campaign-state.4.prefix", batches = {},
  base = { schema = 1, world = "world-23",
    compatibility = "campaign-state.4.prefix", timelineHead = 0, events = 0,
    canonicalDigest = string.rep("1", 16), stateDigest = string.rep("2", 16),
    checkpointRevision = string.rep("3", 16),
    closureDigest = string.rep("4", 16), heads = {},
    state = { world = {}, player = {} }, closed = true,
    tag = string.rep("5", 64) },
  frontier = { version = 1, world = "world-23",
    compatibility = "campaign-state.4.prefix", timelineHead = 0,
    canonicalDigest = string.rep("1", 16), heads = {},
    revision = string.rep("6", 16), tag = string.rep("7", 64) } }
local packageForSend, receivedFrames, resetFrames, resetSource = package23, 0, false, nil
local transfer24 = string.rep("8", 32)
local frames24 = {
  { schema = 1, world = "world-23", compatibility = "campaign-state.4.prefix",
    transfer = transfer24, index = 1, total = 2, kind = "manifest", payload = {} },
  { schema = 1, world = "world-23", compatibility = "campaign-state.4.prefix",
    transfer = transfer24, index = 2, total = 2, kind = "state",
    payload = { path = { "world" }, empty = true } },
}
local foundation23 = {
  apiVersion = 4,
  registerTransport = function(_, transport)
    attached23 = transport
    transport.attach({
      inventory = function() return { signed = "inventory-23" } end,
      missing = function()
        return nil, "replica requires closed-prefix hydration"
      end,
      closedPrefixPackage = function() return packageForSend end,
      closedPrefixFrames = function() return frames24 end,
      adoptClosedPrefix = function(package)
        adopted23 = package
        return true
      end,
      receiveClosedPrefixFrame = function(_, frame)
        receivedFrames = receivedFrames + 1
        return frame.index == frame.total and { installed = true } or "pending"
      end,
      resetClosedPrefixFrames = function(source)
        resetFrames, resetSource = true, source
        return true
      end,
      status = function()
        return { active = true, worldId = "world-23", playerId = "ann" }
      end,
    })
    return true
  end,
}
local bridge23 = assert(Bridge.new({ foundation = foundation23,
  send = function(kind, payload)
    sent23[#sent23 + 1] = { kind = kind, payload = payload }
  end }))
assert(bridge23:install())
eq(bridge23:onInventory("peer-23", { signed = "behind" }), "prefix_sent",
  "a compacted replica pushes its inaccessible prefix to the stale peer")
eq(sent23[#sent23].kind, Bridge.PREFIX,
  "closed-prefix hydration has a dedicated wire kind")
eq(sent23[#sent23].payload.to, "peer-23",
  "the compacted source targets the replica whose inventory is stale")
check(bridge23:onPrefix("peer-23", package23),
  "an authenticated same-world prefix is delegated for adoption")
eq(adopted23.base.closureDigest, package23.base.closureDigest,
  "package interpretation remains in Campaign State")
eq(sent23[#sent23].kind, Bridge.ADVERTISE,
  "successful adoption advertises the exact hydrated frontier")

local largeState = { world = {}, player = {} }
for index = 1, 100 do largeState.world["subject" .. index] = string.rep("\1", 128) end
local largeBase = {}
for key, value in pairs(package23.base) do largeBase[key] = value end
largeBase.state = largeState
packageForSend = { schema = 1, world = package23.world,
  compatibility = package23.compatibility, base = largeBase, batches = {},
  frontier = package23.frontier }
eq(bridge23:onInventory("peer-large", { signed = "behind" }), "prefix_streaming",
  "an oversized package enters acknowledged frame streaming")
eq(sent23[#sent23].kind, Bridge.PREFIX_FRAME,
  "only the first large-package frame is initially in flight")
eq(sent23[#sent23].payload.frame.index, 1,
  "large transfer starts at its first dense frame")
eq(bridge23:onInventory("peer-large", { signed = "still-behind" }),
  "prefix_streaming", "repeat inventory does not restart an active stream")
local beforeAck = #sent23
eq(bridge23:onPrefixFrameAck("peer-large", {
  transfer = transfer24, index = 1 }), "pending",
  "exact acknowledgement releases the next frame")
eq(#sent23, beforeAck + 1, "one acknowledgement releases exactly one frame")
eq(sent23[#sent23].payload.frame.index, 2,
  "acknowledged stream advances densely")
check(bridge23:onPrefixFrameAck("peer-large", {
  transfer = transfer24, index = 2 }),
  "final acknowledgement closes the outgoing stream")
eq(bridge23.prefixOutgoing["peer-large"], nil,
  "completed stream retains no sender queue")
eq(bridge23:onInventory("peer-gone", { signed = "behind" }), "prefix_streaming",
  "another stale peer can begin a bounded stream")
check(bridge23:onPeerUnavailable("peer-gone"),
  "peer departure cancels its outgoing and incoming transfer state")
eq(bridge23.prefixOutgoing["peer-gone"], nil,
  "departed peer retains no sender queue")
eq(resetSource, "peer-gone",
  "Campaign State discards only that peer's incomplete assembler")

eq(bridge23:onPrefixFrame("peer-source", frames24[1]), "pending",
  "recipient stages a nonterminal fragment")
eq(sent23[#sent23].kind, Bridge.PREFIX_FRAME_ACK,
  "every accepted fragment is acknowledged")
check(bridge23:onPrefixFrame("peer-source", frames24[2]),
  "recipient advertises after the final fragment installs")
eq(receivedFrames, 2, "Campaign State receives each fragment exactly once")
eq(sent23[#sent23].kind, Bridge.ADVERTISE,
  "completed fragmented adoption re-enters frontier admission")
bridge23:reset("test disconnect")
check(resetFrames, "transport reset discards incomplete Campaign State assemblers")
eq(resetSource, nil, "full transport reset discards every peer assembler")

-- API 4 makes durable membership the first ordered write after an invited
-- character catches up. No unrelated reservation is admitted in between.
local sent4, attached4, invitationReady, memberState = {}, nil, nil, "absent"
local rejoinSideWrite
local foundation4 = {
  apiVersion = 4,
  registerTransport = function(_, transport)
    attached4 = transport
    transport.attach({
      inventory = function() return { signed = "inventory-4" } end,
      frontier = function() return replicaFrontier end,
      admission = function(_, revision)
        if revision == nil then
          return { state = "matched", replica = { revision = R } }
        end
        return { state = "writable", grantBase = grantBase }
      end,
      validateGrantBase = function() return true end,
      batch = function() return { signed = "membership-events" } end,
      missing = function() return {} end,
      receive = function() return 0 end,
      status = function()
        return { active = true, worldId = "world-19", playerId = "bob" }
      end,
    })
    return true
  end,
  membership = function()
    return { player = "bob", state = memberState, active = memberState == "active" }
  end,
  ensureMembership = function(done)
    if memberState == "active" then return true end
    return attached4.authority:request("bob", "campaign.membership.transition",
      "campaign:member:bob", function(grant, why)
        if not grant then return done(nil, why) end
        memberState = "active"
        attached4.authority:commit(grant.grant,
          { { kind = "campaign.membership.transition" } })
        done({ { kind = "campaign.membership.transition" } })
      end)
  end,
  rejoinMembership = function(done)
    if memberState ~= "left" then return nil, "membership is not left" end
    rejoinSideWrite = attached4.authority:request("bob",
      "pokemon.unique.resolve", "articuno")
    return attached4.authority:request("bob", "campaign.membership.transition",
      "campaign:member:bob", function(grant, why)
        if not grant then return done(nil, why) end
        memberState = "active"
        attached4.authority:commit(grant.grant,
          { { kind = "campaign.membership.transition" } })
        done({ { kind = "campaign.membership.transition" } })
      end)
  end,
  invitation = function(done) invitationReady = done; return "pending" end,
  acceptInvitation = function() return true end,
}
local bridge4 = assert(Bridge.new({ foundation = foundation4,
  frontierAdmission = true,
  send = function(kind, payload)
    sent4[#sent4 + 1] = { kind = kind, payload = payload }
  end }))
check(bridge4:install(), "API-4 membership bridge installs")
check(bridge4:advertise(), "invited replica advertises before membership")
assert(bridge4:onFrontier(authorityFrontier))
local membershipEcho = sent4[#sent4].payload.admission
check(bridge4:onFrontierReady(membershipEcho),
  "frontier admission begins canonical self-membership")
eq(sent4[#sent4].kind, Bridge.SEQUENCE_REQUEST,
  "membership obtains ordinary canonical authority")
eq(sent4[#sent4].payload.kind, "campaign.membership.transition",
  "the transport carries membership without owning its meaning")
eq(bridge4.authorized, false,
  "unrelated writes remain gated while membership is pending")
local memberRequest = sent4[#sent4].payload.request
check(bridge4:onGrant({ request = memberRequest, grant = "member-grant",
  world = "world-19", position = 4, base = grantBase }),
  "the exact membership grant reaches Campaign State")
eq(memberState, "active", "the invited stable player becomes canonically active")
eq(sent4[#sent4].kind, Bridge.SEQUENCE_COMMIT,
  "membership commits before ordinary world writes resume")

assert(bridge4:onFrontier(authorityFrontier))
local activeEcho = sent4[#sent4].payload.admission
check(bridge4:onFrontierReady(activeEcho),
  "an already active member passes the next frontier admission")
check(bridge4.authorized,
  "ordinary ordered writes resume only after active membership is observed")
eq(bridge4:invite("peer"), "pending",
  "asynchronous invitation preparation remains non-blocking")
check(type(invitationReady) == "function",
  "the bridge retains the exact invitation completion callback")
invitationReady({ signed = "invitation-4" })
eq(sent4[#sent4].kind, Bridge.INVITE,
  "a prepared invitation is sent exactly once")

memberState = "left"
check(bridge4:advertise(), "a departed stable player may still advertise its frontier")
assert(bridge4:onFrontier(authorityFrontier))
local leftEcho = sent4[#sent4].payload.admission
check(bridge4:onFrontierReady(leftEcho),
  "frontier admission recognizes departure without undoing it")
check(bridge4:membershipConsentRequired(),
  "departed membership exposes an explicit consent boundary")
eq(bridge4.authorized, false,
  "departure cannot authorize ordinary shared-world writes")
eq(attached4.authority:request("bob", "pokemon.unique.resolve", "articuno"), nil,
  "unrelated writes remain blocked before rejoin consent")
eq(bridge4:rejoinMembership(), "pending",
  "explicit consent begins the canonical rejoin transition")
eq(rejoinSideWrite, nil,
  "the consent window authorizes membership and no unrelated write")
eq(sent4[#sent4].payload.kind, "campaign.membership.transition",
  "rejoin uses the ordinary canonical membership kind")
local rejoinRequest = sent4[#sent4].payload.request
check(bridge4:onGrant({ request = rejoinRequest, grant = "rejoin-grant",
  world = "world-19", position = 4, base = grantBase }),
  "the exact rejoin grant reaches Campaign State")
eq(memberState, "active", "rejoin restores the same stable character")
eq(bridge4.authorized, false,
  "ordinary writes still wait for the frontier produced by rejoin")
check(not bridge4:membershipConsentRequired(),
  "consumed rejoin consent is not reusable")

print(("campaign state MMO bridge: %d assertions passed"):format(passed))
