-- SPDX-License-Identifier: GPL-3.0-only
-- A data-only English catalog. Parsing has no engine or filesystem effects.
local M = {}
local function code(value) return value:match("^[a-z][a-z'%-]*$") ~= nil end
local function text(value)
  return value ~= '' and utf8.len(value) ~= nil and not value:find('[%z\1-\31\127]')
end

function M.parse(bytes)
  if type(bytes) ~= 'string' or bytes:find('\r[^\n]') then return nil end
  bytes = bytes:gsub('\r\n', '\n')
  if bytes:sub(-1) ~= '\n' then return nil end
  local records, seen, line_number = {}, {}, 0
  for line in bytes:gmatch('([^\n]*)\n') do
    line_number = line_number + 1
    if line_number == 1 then
      if line ~= 'format\t1' then return nil end
    else
      local fields = {}
      for field in (line .. '\t'):gmatch('(.-)\t') do fields[#fields + 1] = field end
      if #fields ~= 9 then return nil end
      local kind, alias, canonical, native, shown, count, ordinary, parent_code, parent_text = table.unpack(fields)
      if (kind ~= 'word' and kind ~= 'alias') or not code(alias) or not code(canonical)
          or not text(native) or not count:match('^[1-9]%d*$')
          or tonumber(count) > 2147483647 or (ordinary ~= '0' and ordinary ~= '1') then return nil end
      if kind == 'word' then
        if alias ~= canonical or canonical ~= native or shown ~= '-' or ordinary ~= '1'
            or parent_code ~= '-' or parent_text ~= '-' then return nil end
      elseif shown == '-' or not text(shown) then return nil end
      if (parent_code == '-') ~= (parent_text == '-') then return nil end
      if parent_code ~= '-' and (not code(parent_code) or not text(parent_text)) then return nil end
      local key = alias .. '\t' .. canonical .. '\t' .. native
      if seen[key] then return nil end
      seen[key] = true
      records[#records + 1] = {alias=alias, code=canonical, word=native,
        shown=kind == 'alias' and shown or nil, frequency=tonumber(count),
        ordinary=ordinary == '1', expansion=parent_code ~= '-' and 1 or 0,
        parent=parent_code ~= '-' and (parent_code .. '\t' .. parent_text) or nil}
    end
  end
  if line_number < 2 then return nil end
  return records
end

function M.validate(bytes) return M.parse(bytes) ~= nil end
return M
