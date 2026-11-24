-- SPDX-License-Identifier: GPL-3.0-only
-- Fixed resources follow the same user-first order as Rime configuration.
local M = {}

local function readable(path)
  local file = io.open(path, 'rb')
  if not file then return false end
  file:close()
  return true
end

function M.path(relative, optional)
  local user = rime_api.get_user_data_dir() .. '/' .. relative
  if readable(user) then return user end
  local shared = rime_api.get_shared_data_dir() .. '/' .. relative
  if readable(shared) then return shared end
  if optional then return user end
  error('Missing scheme resource: ' .. relative)
end

function M.directory(relative, anchor)
  local path = M.path(relative .. '/' .. anchor)
  return path:sub(1, #path - #anchor - 1)
end

return M
