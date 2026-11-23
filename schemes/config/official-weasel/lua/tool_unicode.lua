-- Ice-style exact codepoint plus one appended hexadecimal digit (GPL-3.0).
-- Local changes: scalar/control checks, named exact-only invisible characters.
local data = require('tool_unicode_data')
local M = {}

local function in_ranges(cp, ranges)
  for _, range in ipairs(ranges) do
    if cp < range[1] then return false end
    if cp <= range[2] then return true end
  end
  return false
end

local function invisible_name(cp)
  if data.names[cp] then return data.names[cp] end
  if cp >= 0xe0100 and cp <= 0xe01ef then return 'VARIATION SELECTOR-' .. (cp - 0xe0100 + 17) end
  if cp >= 0xe0020 and cp <= 0xe007e then return 'TAG ' .. string.char(cp - 0xe0000) end
  if cp == 0xe007f then return 'CANCEL TAG' end
  if cp == 0xe0001 then return 'LANGUAGE TAG' end
  return '預設不可見字元'
end

local function allowed(cp)
  return cp <= 0x10ffff and not (cp >= 0xd800 and cp <= 0xdfff)
      and not in_ranges(cp, data.blocked)
end

function M.query(input)
  local hex = input:match('^U(%x+)$')
  if not hex or #hex < 2 then return {}, '請輸入十六進位碼點' end
  local cp = tonumber(hex, 16)
  if #hex > 6 or cp > 0x10ffff then return {}, 'Invalid Unicode' end
  local result = {}
  local function add(value, completion)
    if not allowed(value) then return end
    local hidden = in_ranges(value, data.invisible)
    if hidden and completion then return end
    local comment = string.format('U+%04X', value)
    if hidden then comment = comment .. ' · ' .. invisible_name(value)
    elseif completion then comment = comment .. ' · 补全' end
    result[#result + 1] = {text=utf8.char(value), comment=comment}
  end
  add(cp, false)
  if cp < 0x10000 then for digit = 0, 15 do add(cp * 16 + digit, true) end end
  return result, #result == 0 and 'Unsupported Character' or nil
end

return M
