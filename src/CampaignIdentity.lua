-- Bounded opaque identifiers used only by the optional campaign_state
-- transport adapter. Kept separate from Wire.id because campaign identities
-- and grant tokens are not MMO connection ids and deliberately have wider
-- limits.

local M = {}

function M.identifier(value, maxLength)
  if type(value) ~= "string" or type(maxLength) ~= "number" then return nil end
  if #value < 1 or #value > maxLength then return nil end
  if not value:match("^[%w_%.:%-]+$") then return nil end
  return value
end

return M
