local data = require('cn_extra_forms')
local M = {}
-- Profiles are read-only after construction. Live translator envs keep their
-- selected table alive; unused profiles need not remain in the module cache.
local profiles = setmetatable({}, {__mode='v'})

-- Missing YAML keys use the agreed defaults. Explicit false stays false.
function M.from_config(config)
  return M.enabled({
    missing_letter = config:get_bool('cn_tolerance/missing_letter') ~= false,
    neighbor_substitution = config:get_bool('cn_tolerance/neighbor_substitution') ~= false,
    double_transposition = config:get_bool('cn_tolerance/double_transposition') ~= false,
  })
end

function M.enabled(options)
  local selected = (options.missing_letter and 1 or 0)
                 | (options.neighbor_substitution and 2 or 0)
                 | (options.double_transposition and 4 or 0)
  local cached = profiles[selected]
  if cached then return cached end
  local result = {}
  for syllable, values in pairs(data) do
    local active = {}
    for raw, mask in pairs(values) do
      local enabled = mask & selected
      if enabled ~= 0 then active[raw] = (enabled & 3) ~= 0 and 1 or 2 end
    end
    result[syllable] = active
  end
  profiles[selected] = result
  return result
end

return M
