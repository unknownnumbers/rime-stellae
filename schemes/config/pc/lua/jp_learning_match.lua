-- Reuse the deployed Chinese spelling tables for the small set of learned
-- JP words. This never scans the static Japanese word dictionary.
local forms = require('cn_forms')
local data = require('jp_v_data')
local family = require('jp_family')
local M = {}

local function better(a, b)
  return not b or a.kind < b.kind or (a.kind == b.kind and a.edits < b.edits)
end

function M.pinyin(text, raw, extras)
  if utf8.len(text) > #raw then return {} end
  local positions = {[0]={kind=0, edits=0, vertices={0}}}
  local _, letters = raw:gsub('[a-z]', '')
  for _, cp in utf8.codes(text) do
    local record = data.get_character(utf8.char(cp))
    local following = {}
    for offset, previous in pairs(positions) do
      for _, syllable in ipairs(record and record.pinyin or {}) do
        local spelling, extra = forms[syllable], extras and extras[syllable]
        if spelling then
          for length = 1, math.min(spelling.max_length, #raw - offset) do
            local part = raw:sub(offset + 1, offset + length)
            local kind, edits = spelling.values[part], 0
            if kind == 2 then edits = 1 end
            if kind == nil and extra and extra[part] then kind, edits = 2, extra[part] end
            if kind and (kind < 2 or letters >= 3) then
              local ending = offset + length
              while raw:sub(ending + 1, ending + 1):match("[' ]") do ending = ending + 1 end
              local match = {kind=math.max(previous.kind, kind), edits=previous.edits + edits}
              if better(match, following[ending]) then
                match.vertices = {table.unpack(previous.vertices)}
                match.vertices[#match.vertices + 1] = ending
                following[ending] = match
              end
            end
          end
        end
      end
    end
    positions = following
    if next(positions) == nil then return {} end
  end
  return positions
end

function M.q(text, raw, readings)
  local found = {}
  if utf8.len(text) > #raw then return found end
  for ending, vertices in pairs(family.q_prefix_ends(text, raw)) do
    found[ending] = {kind=0, edits=0, vertices=vertices}
  end
  local prefix = raw:sub(1, 1) == 'q' and 1 or 0
  local query = raw:sub(prefix + 1):lower()
  for code in require('jp_query').lookup_codes(text):gmatch('%S+') do
    if query:sub(1, #code) == code then
      local ending = prefix + #code
      while raw:sub(ending + 1, ending + 1):match("[' ]") do ending = ending + 1 end
      found[ending] = {kind=0, edits=0, vertices={0, ending}}
    end
  end
  for _, record in ipairs(readings or {}) do
    local ending, vertices = require('jp_reading_metadata').match(record, query)
    if ending then
      for index, vertex in ipairs(vertices) do vertices[index] = prefix + vertex end
      found[prefix + ending] = {kind=0, edits=0, vertices=vertices}
    end
  end
  return found
end

return M
