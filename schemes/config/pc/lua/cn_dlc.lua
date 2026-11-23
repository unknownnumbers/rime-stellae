-- SPDX-License-Identifier: GPL-3.0-only
local catalog = require('rymcp_dlc')
local M = {}
local managed = {
  rymcp_dlc_math=true, rymcp_dlc_physics=true,
  rymcp_dlc_computer=true, rymcp_dlc_poetry=true,
}
for index = 0, 31 do managed[string.format('rymcp_dlc_poetry_%02d', index)] = true end

function M.configure(config, engine)
  local snapshot = catalog.modules(engine)
  local enabled = {}
  for _, module in ipairs(snapshot) do
    if module.languages.cn then
      for _, name in ipairs(module.packs) do enabled[name] = true end
    end
  end
  local configured = config:get_list('translator/packs')
  local selected, seen = ConfigList(), {}
  for i = 0, configured and configured.size - 1 or -1 do
    local value = configured:get_value_at(i)
    local name = value and value.value
    if name and not seen[name] and (not managed[name] or enabled[name]) then
      selected:append(ConfigValue(name).element)
      seen[name] = true
    end
  end
  config:set_item('translator/packs', selected.element)
  return snapshot
end

return M
