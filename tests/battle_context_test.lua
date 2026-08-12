local cache = {}
local function need(name)
  if cache[name] then return cache[name] end
  local value = assert(loadfile("src/" .. name .. ".lua"))(need, {})
  cache[name] = value; return value
end
local Context = need("BattleContext")
local passed = 0
local function check(value, message) assert(value, message); passed = passed + 1 end

local base = assert(Context.normalize({ occurrence = "rby:route22:ann.1",
  definition = "0123456789abcdef" }))
check(base.requirements == nil, "v1 battle contexts remain valid and policy-free")
local declared = assert(Context.normalize({ occurrence = base.occurrence,
  definition = base.definition, requirements = {
    joinPolicy = "automatic-second-slot", enrollmentCutoff = "resolution",
    fleeAllowed = false,
  } }))
check(declared.requirements.joinPolicy == "automatic-second-slot",
  "content may request the advertised automatic trainer slot")
check(declared.requirements.fleeAllowed == false,
  "content may explicitly prohibit trainer fleeing")
check(not Context.same(base, declared),
  "providers cannot silently disagree about battle behavior")
check(declared.requirements.enrollmentCutoff == "resolution",
  "content may keep trainer enrollment open through active battle")
check(not Context.normalize({ occurrence = base.occurrence,
  definition = base.definition, requirements = {
    enrollmentCutoff = "departure",
  } }), "unknown enrollment cutoffs are rejected rather than ignored")
local capabilities = Context.capabilities()
check(capabilities[1] == "automatic-trainer-second-slot"
  and capabilities[2] == "late-trainer-join-through-active-battle"
  and capabilities[3] == "trainer-flee-policy",
  "only implemented battle-context capabilities are advertised")

print(("battle context policy: %d assertions passed"):format(passed))
