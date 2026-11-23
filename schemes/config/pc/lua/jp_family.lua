-- Canonical JP word identities are generated from verified public relations.
-- An unattested compound is deliberately its own identity.
local data = require('jp_family_data')
local M = {}

function M.resolve(text) return data.aliases[text] or text end
local function q_prefix_ends(text, raw)
  local positions = {[1]={0}}
  for _, cp in utf8.codes(text) do
    local next_positions = {}
    for position, path in pairs(positions) do
      for _, code in ipairs(data.q_codes[utf8.char(cp)] or {}) do
        if raw:sub(position, position + #code - 1) == code then
          local ending = position + #code
          while raw:sub(ending, ending):match("[' ]") do ending = ending + 1 end
          local following = {}
          for _, vertex in ipairs(path) do following[#following + 1] = vertex end
          following[#following + 1] = ending - 1
          next_positions[ending] = following
        end
      end
    end
    positions = next_positions
  end
  local endings = {}
  for position, path in pairs(positions) do endings[position - 1] = path end
  return endings
end

local function matches_q(text, raw)
  local path = q_prefix_ends(text, raw)[#raw]
  return path ~= nil, path
end

function M.members(text, options)
  local canonical = M.resolve(text)
  local members = data.groups[canonical] or {canonical}
  if not options then return members end
  local admitted = {}
  for _, member in ipairs(members) do
    local matches = not options.q or matches_q(member, options.q)
    if options.reading then
      local reading_matches = false
      for _, reading in ipairs(data.readings[member] or {}) do
        if reading == options.reading then reading_matches = true; break end
      end
      matches = matches and reading_matches
    end
    if matches then admitted[#admitted + 1] = member end
  end
  return admitted
end
M.matches_q = matches_q
M.q_prefix_ends = q_prefix_ends
function M.known(text)
  return require('jp_v_data').get_word(M.resolve(text)) ~= nil
end
function M.is_han(text)
  if text == '' then return false end
  for _, cp in utf8.codes(text) do
    if not require('jp_v_data').get_character(utf8.char(cp)) then return false end
  end
  return true
end
return M
