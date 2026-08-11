local root, cache = "src/", {}
local function need(name)
  if cache[name] then return cache[name] end
  local chunk, why = loadfile(root .. name .. ".lua")
  assert(chunk, why)
  local value = chunk(need, {})
  cache[name] = value
  return value
end

local Hub, Wire = need("Hub"), need("Wire")
local CampaignWire = need("CampaignWire")
local passed = 0
local function check(value, message) assert(value, message); passed = passed + 1 end
local function eq(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": expected "
    .. tostring(expected) .. ", got " .. tostring(actual))
  passed = passed + 1
end
local function peer()
  local value = { outbox = {} }
  function value:send(message) self.outbox[#self.outbox + 1] = message end
  function value:close() self.closed = true end
  return value
end
local function take(remote, kind)
  for index, message in ipairs(remote.outbox) do
    if message.type == kind then return table.remove(remote.outbox, index) end
  end
end
local function join(hub, name)
  local remote = peer()
  local client = assert(hub:accept(remote))
  local idDigit = ("%x"):format((name:byte(1) or 0) % 16)
  hub:receive(client, { type = Wire.HELLO, proto = 19, name = name,
    playerId = string.rep(idDigit, 32),
    map = "PALLET", x = 1, y = 1, facing = "down" })
  assert(take(remote, Wire.WELCOME))
  return client, remote
end

local hub = Hub.new({ maxPlayers = 2, protocol = 19 })
local ann, annPeer = join(hub, "ANN")
local bob, bobPeer = join(hub, "BOB")
local tag = string.rep("a", 64)
local D0, R0 = string.rep("b", 16), string.rep("c", 16)
local function inventory(player, head, heads)
  return { schema = 1, world = "frontier-world",
    compatibility = "campaign-state.4.frontier", player = player,
    timelineHead = head, heads = heads, tag = tag }
end
local function frontier(head, digest, revision, heads)
  return { version = 1, world = "frontier-world",
    compatibility = "campaign-state.4.frontier", timelineHead = head,
    canonicalDigest = digest, heads = heads, revision = revision, tag = tag }
end
local function base(position, digest, revision)
  return { version = 1, world = "frontier-world",
    compatibility = "campaign-state.4.frontier", position = position,
    baseDigest = digest, authorityRevision = revision,
    replicaRevision = revision }
end
local function acknowledge(client, remote, localFrontier, grantBase)
  hub:receive(client, { type = CampaignWire.FRONTIER_ACK,
    admission = { frontier = localFrontier,
      authorityRevision = grantBase.authorityRevision,
      replicaRevision = grantBase.replicaRevision, grantBase = grantBase } })
  return take(remote, CampaignWire.FRONTIER_READY)
end

local heads0 = { ann = 0, bob = 0 }
local initial = frontier(0, D0, R0, heads0)
hub:receive(ann, { type = CampaignWire.ADVERTISE,
  inventory = inventory("ann", 0, heads0), frontier = initial })
eq(take(annPeer, CampaignWire.READY), nil,
  "protocol 18 ready cannot admit a protocol 19 client")
eq(take(annPeer, CampaignWire.FRONTIER).frontier.revision, R0,
  "first replica seeds the in-memory authority frontier")
hub:receive(bob, { type = CampaignWire.ADVERTISE,
  inventory = inventory("bob", 0, heads0), frontier = initial })
eq(take(bobPeer, CampaignWire.FRONTIER).frontier.revision, R0,
  "second replica receives the retained authority frontier")

local base0 = base(1, D0, R0)
hub:receive(ann, { type = CampaignWire.SEQUENCE_REQUEST,
  request = "early", actor = "ann", kind = "pokemon.unique.resolve",
  subject = "articuno", base = base0 })
eq(take(annPeer, CampaignWire.SEQUENCE_GRANT), nil,
  "a grant base cannot bypass acknowledgement")
check(acknowledge(ann, annPeer, initial, base0),
  "first exact acknowledgement is echoed")
check(acknowledge(bob, bobPeer, initial, base0),
  "second exact acknowledgement is echoed")

hub:receive(ann, { type = CampaignWire.SEQUENCE_REQUEST,
  request = "one", actor = "ann", kind = "pokemon.unique.resolve",
  subject = "articuno", base = base0 })
local grant = assert(take(annPeer, CampaignWire.SEQUENCE_GRANT))
eq(grant.position, 1, "acknowledged base receives the exact next position")
eq(grant.base.baseDigest, D0, "grant echoes its admitted base")
local event = { schema = 1, id = "ann:1", world = "frontier-world",
  actor = "ann", seq = 1, position = 1,
  transaction = "frontier-transaction-one", owner = "world",
  kind = "pokemon.unique.resolve", subject = "articuno",
  payload = { outcome = "captured" } }
hub:receive(ann, { type = CampaignWire.EVENTS,
  envelope = { schema = 1, world = "frontier-world",
    compatibility = "campaign-state.4.frontier", events = { event }, tag = tag } })
hub:receive(ann, { type = CampaignWire.SEQUENCE_COMMIT,
  request = grant.request, grant = grant.grant,
  world = grant.world, position = grant.position })

local D1, R1 = string.rep("d", 16), string.rep("e", 16)
local heads1 = { ann = 1, bob = 0 }
local advanced = frontier(1, D1, R1, heads1)
hub:receive(ann, { type = CampaignWire.ADVERTISE,
  inventory = inventory("ann", 1, heads1), frontier = advanced })
eq(take(bobPeer, CampaignWire.SEQUENCE_GRANT), nil,
  "commit and resulting advertisement still wait for acknowledgement")
eq(take(bobPeer, CampaignWire.FRONTIER).frontier.revision, R1,
  "new authority frontier revokes every old admission")
eq(take(annPeer, CampaignWire.FRONTIER).frontier.revision, R1,
  "the publishing replica also re-enters through the new authority frontier")
check(acknowledge(ann, annPeer, advanced, base(2, D1, R1)),
  "resulting frontier acknowledgement releases the committed occupant")
hub:receive(bob, { type = CampaignWire.ADVERTISE,
  inventory = inventory("bob", 1, heads1), frontier = advanced })
take(bobPeer, CampaignWire.FRONTIER)
check(acknowledge(bob, bobPeer, advanced, base(2, D1, R1)),
  "peer re-enters writable state at the new frontier")
hub:receive(bob, { type = CampaignWire.SEQUENCE_REQUEST,
  request = "two", actor = "bob", kind = "pokemon.unique.resolve",
  subject = "zapdos", base = base(2, D1, R1) })
local grant2 = assert(take(bobPeer, CampaignWire.SEQUENCE_GRANT))
eq(grant2.position, 2,
  "next writer advances only from the acknowledged resulting frontier")

local event2 = { schema = 1, id = "bob:1", world = "frontier-world",
  actor = "bob", seq = 1, position = 2,
  transaction = "frontier-transaction-two", owner = "world",
  kind = "pokemon.unique.resolve", subject = "zapdos",
  payload = { outcome = "escaped" } }
hub:receive(bob, { type = CampaignWire.EVENTS,
  envelope = { schema = 1, world = "frontier-world",
    compatibility = "campaign-state.4.frontier", events = { event2 }, tag = tag } })
hub:receive(ann, { type = CampaignWire.SEQUENCE_REQUEST,
  request = "held-three", actor = "ann", kind = "pokemon.unique.resolve",
  subject = "mewtwo", base = base(2, D1, R1) })
hub:receive(bob, { type = CampaignWire.SEQUENCE_CANCEL,
  request = grant2.request, grant = grant2.grant })
eq(take(annPeer, CampaignWire.SEQUENCE_GRANT), nil,
  "cancel cannot release a position after its signed occupant was relayed")
check(hub:drop(bob), "publisher can disconnect after its signed occupant is relayed")

local D2, R2 = string.rep("f", 16), string.rep("1", 16)
local heads2 = { ann = 1, bob = 1 }
local recovered = frontier(2, D2, R2, heads2)
hub:receive(ann, { type = CampaignWire.ADVERTISE,
  inventory = inventory("ann", 2, heads2), frontier = recovered })
eq(take(annPeer, CampaignWire.FRONTIER).frontier.revision, R2,
  "a surviving replica can prove the disconnected publisher's frontier")
local staleBase = base(3, D2, string.rep("2", 16))
eq(acknowledge(ann, annPeer, recovered, staleBase), nil,
  "a stale authority revision cannot release the recovered position")
check(acknowledge(ann, annPeer, recovered, base(3, D2, R2)),
  "an exact recovered frontier acknowledgement releases the position")
hub:receive(ann, { type = CampaignWire.SEQUENCE_REQUEST,
  request = "three", actor = "ann", kind = "pokemon.unique.resolve",
  subject = "mewtwo", base = base(3, D2, R2) })
eq(take(annPeer, CampaignWire.SEQUENCE_GRANT).position, 3,
  "recovery never reuses the already published canonical position")

local R3 = string.rep("3", 16)
local heads3 = { ann = 2, bob = 1 }
local actorAdvanced = frontier(2, D2, R3, heads3)
hub:receive(ann, { type = CampaignWire.ADVERTISE,
  inventory = inventory("ann", 2, heads3), frontier = actorAdvanced })
eq(take(annPeer, CampaignWire.FRONTIER).frontier.revision, R3,
  "the stable player may advance only its own actor head without a world event")
check(acknowledge(ann, annPeer, actorAdvanced, base(3, D2, R3)),
  "actor-only history re-enters through an exact fresh acknowledgement")
hub:receive(ann, { type = CampaignWire.SEQUENCE_REQUEST,
  request = "three-after-actor", actor = "ann", kind = "pokemon.unique.resolve",
  subject = "mewtwo", base = base(3, D2, R3) })
eq(take(annPeer, CampaignWire.SEQUENCE_GRANT).position, 3,
  "actor-only history revokes but does not consume an unpublished reservation")

local copy, copyPeer = join(hub, "COPY")
hub:receive(copy, { type = CampaignWire.ADVERTISE,
  inventory = inventory("ann", 2, heads3), frontier = actorAdvanced })
eq(take(copyPeer, CampaignWire.UNAVAILABLE).reason, "duplicate_player",
  "a copied save cannot connect under an already live stable player")

local restarted = Hub.new({ maxPlayers = 2, protocol = 19 })
local behind, behindPeer = join(restarted, "BEHIND")
local ahead, aheadPeer = join(restarted, "AHEAD")
restarted:receive(behind, { type = CampaignWire.ADVERTISE,
  inventory = inventory("ann", 0, heads0), frontier = initial })
take(behindPeer, CampaignWire.FRONTIER)
restarted:receive(ahead, { type = CampaignWire.ADVERTISE,
  inventory = inventory("bob", 1, heads1), frontier = advanced })
eq(take(aheadPeer, CampaignWire.FRONTIER).frontier.revision, R0,
  "a restarted hub does not choose the longest returning save as authority")
local gapEvent = { schema = 1, id = "bob:2", world = "frontier-world",
  actor = "bob", seq = 2, position = 2,
  transaction = "frontier-transaction-gap", owner = "world",
  kind = "pokemon.unique.resolve", subject = "moltres",
  payload = { outcome = "escaped" } }
local gapHeads = { ann = 0, bob = 2 }
local gapFrontier = frontier(2, D2, R2, gapHeads)
restarted:receive(ahead, { type = CampaignWire.EVENTS, to = behind.id,
  envelope = { schema = 1, world = "frontier-world",
    compatibility = "campaign-state.4.frontier", events = { gapEvent }, tag = tag } })
take(behindPeer, CampaignWire.EVENTS)
restarted:receive(behind, { type = CampaignWire.ADVERTISE,
  inventory = inventory("ann", 2, gapHeads), frontier = gapFrontier })
eq(take(behindPeer, CampaignWire.FRONTIER).frontier.revision, R0,
  "sparse relayed evidence cannot skip a canonical position after restart")
restarted:receive(ahead, { type = CampaignWire.EVENTS, to = behind.id,
  envelope = { schema = 1, world = "frontier-world",
    compatibility = "campaign-state.4.frontier", events = { event }, tag = tag } })
check(take(behindPeer, CampaignWire.EVENTS),
  "the ahead replica relays its signed missing occupant to the returner")
restarted:receive(behind, { type = CampaignWire.ADVERTISE,
  inventory = inventory("ann", 1, heads1), frontier = advanced })
eq(take(behindPeer, CampaignWire.FRONTIER).frontier.revision, R1,
  "contiguous relayed evidence promotes the caught-up restart frontier")
restarted:receive(behind, { type = CampaignWire.FRONTIER_ACK,
  admission = { frontier = advanced, authorityRevision = R1,
    replicaRevision = R1, grantBase = base(2, D1, R1) } })
check(take(behindPeer, CampaignWire.FRONTIER_READY),
  "restart recovery becomes writable only after exact acknowledgement")
restarted:receive(behind, { type = CampaignWire.SEQUENCE_REQUEST,
  request = "restart-two", actor = "ann", kind = "pokemon.unique.resolve",
  subject = "moltres", base = base(2, D1, R1) })
eq(take(behindPeer, CampaignWire.SEQUENCE_GRANT).position, 2,
  "restart recovery preserves rather than reuses the recovered head")

print(("campaign frontier embedded hub: %d assertions passed"):format(passed))
