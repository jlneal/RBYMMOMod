# Flexible Party vs Wild — v1 design and proof boundary

## Contract

- `WILD CO-OP` is the host-side master switch. Off leaves engine Wild battles local.
- A Wild encounter begins immediately with the initiating player and one Wild seat.
- A second player may join later through `JOIN`; rejoining after an individual flee is allowed.
- `OFF-MAP JOIN` controls whether an online party member outside the encounter map is eligible.
  It never teleports a player: they must reach and interact with the encounter normally.
- `PROX JOIN` is host permission. The client's `AUTO JOIN RANGE` is `OFF`, `1`–`8`, or
  `SAME MAP`; `SAME MAP` is the default. Manual `JOIN` remains available when auto-join is off.
- Host policy is captured when hosting begins and does not mutate until the server restarts.
- `2ND WILD` remains a separate host probability. It is evaluated only when the second human
  is admitted; zero means the existing one-Wild field is retained.
- An individual runner vacates their stable ally seat while another human remains. Rejoining
  restores the retained in-battle party state; it cannot upload a healed or substituted party.

## Authority and boundaries

The hub's existing mediated `BattleSim` remains the sole authority. There is no client-hosted
Wild simulator and therefore no authority transfer. Admission is legal only at a pristine
choice boundary: `phase == choice`, no forced-only continuation, and no fighter has committed
a choice. A request received later is queued for the next such boundary.

The simulator proof surface is mirrored in Lua and Node:

1. Start `coop_wild` as one human versus one synthetic Wild seat.
2. Admit the second human at the untouched first choice boundary.
3. Refuse admission after any choice is committed.
4. Let one human RUN without ending the encounter while another remains.
5. Refuse choices and disconnect-grace operations for a voluntarily vacant seat.
6. Readmit the same player into the same field slot with retained HP and party state.
7. Preserve legacy concession behavior for every mode other than `coop_wild`.

## Protocol slice

The fixed-roster v1.0.3 messages cannot hydrate a client that enters after earlier events were
drained. The flexible version therefore requires a protocol bump and three explicit operations:

- **offer** — identifies the live Wild battle, encounter map, initiator, and join eligibility;
- **admit request/result** — uploads the first-time joiner's party and reports whether it was
  admitted now or queued for the next choice boundary;
- **battle sync** — sends the authoritative roster, full retained party sheets, active indices,
  HP/status/volatile state needed to construct the existing `CoopBattle` field, current turn,
  and next event sequence.

A sync is a point-in-time state transfer, not replayed history. After applying it, the joining
client consumes the ordinary ordered `mmo.battle_event` stream. The hub must add the member to
the broadcast roster before sending the sync so no event can fall between those operations.

## Delivery slices

1. **Simulator foundation** — dynamic stable seats and independent flee, twin-proved.
2. **Hub lifecycle** — live offer, queued boundary admission, retained membership, sync export.
3. **Client lifecycle** — persistent `JOIN`, proximity policy, late `CoopBattle` construction,
   independent return to the overworld, and rejoin.
4. **Optional second Wild** — roll only on second-human admission, add the second synthetic seat
   at the same boundary, then extend target/catch ownership tests.
5. **End-to-end proof** — embedded Lua hub and Node hub: immediate solo start, manual late join,
   numeric/SAME MAP proximity, off-map policy, individual flee/rejoin, catch, disconnect, and
   unchanged trainer/1v1 behavior.

## Non-goals for this slice

- Parties larger than two.
- Shared campaign/progression state (the independent Shared Campaign mod owns that layer).
- Synchronizing or selecting overworld Wild entities; the encounter's existing normalized Wild
  identity is the input, and world persistence remains a separate subsystem.
