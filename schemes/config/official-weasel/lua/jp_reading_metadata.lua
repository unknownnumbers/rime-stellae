-- Research prototype. This module creates no Memory and owns no counter.
-- Every row lives in the existing jp_family user dictionary, with commits=0.
local M = {prefix='@jpq1|'}

local function hex(value)
  return (value:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end
local function unhex(value)
  if #value % 2 ~= 0 then return nil end
  return (value:gsub('..', function(c) return string.char(tonumber(c, 16)) end))
end

function M.capture(raw, body_start, candidate, absolute_vertices)
  local start, ending = math.max(body_start, candidate.start), candidate._end
  if ending <= start or ending > #raw then return nil end
  local code = raw:sub(start + 1, ending):lower()
  if not code:match("^[a-z' ]+$") then return nil end
  local vertices, seen = {0}, {[0]=true}
  for _, vertex in ipairs(absolute_vertices or {}) do
    local relative = vertex - start
    -- In particular, never retain the unselected suffix's final endpoint.
    if relative > 0 and relative < #code and not seen[relative] then
      vertices[#vertices + 1], seen[relative] = relative, true
    end
  end
  table.sort(vertices)
  vertices[#vertices + 1] = #code
  return {text=candidate.text, code=code, vertices=vertices}
end

function M.encode(record)
  return M.prefix .. hex(record.code) .. '|' .. table.concat(record.vertices, ',') .. ' '
end

function M.decode(entry)
  local encoded, stops = entry.custom_code:match('^@jpq1|([0-9a-f]+)|([0-9,]+) $')
  if not encoded then return nil end
  local code = unhex(encoded)
  if not code or not code:match("^[a-z' ]+$") then return nil end
  local vertices, previous = {}, -1
  for value in stops:gmatch('%d+') do
    local vertex = tonumber(value)
    if vertex <= previous or vertex > #code then return nil end
    vertices[#vertices + 1], previous = vertex, vertex
  end
  if vertices[1] ~= 0 or vertices[#vertices] ~= #code then return nil end
  return {text=entry.text, code=code, vertices=vertices}
end

function M.store(memory, record, canonical)
  local entry = DictEntry()
  entry.text, entry.custom_code, entry.weight = canonical or record.text, M.encode(record), 0
  -- No commit tick increase and no second selection count.
  return memory:update_userdict(entry, 0, '')
end

function M.list(memory, learned)
  local result, active = {}, {}
  for _, entry in ipairs(learned) do active[entry.text] = entry.commit_count > 0 end
  if memory:user_lookup(M.prefix, true) then
    for entry in memory:iter_user() do
      -- Shift+Delete makes the canonical row invisible. Stored metadata alone
      -- cannot revive it, add a boost, or manufacture a learned candidate.
      if entry.commit_count == 0 and active[entry.text] then
        local record = M.decode(entry)
        if record then result[#result + 1] = record end
      end
    end
  end
  return result
end

function M.match(record, query)
  query = query:lower()
  if query:sub(1, #record.code) ~= record.code then return nil end
  local ending = #record.code
  while query:sub(ending + 1, ending + 1):match("[' ]") do ending = ending + 1 end
  local vertices = {table.unpack(record.vertices)}
  vertices[#vertices] = ending
  return ending, vertices
end

-- Invoke only inside the existing Memory:memorize callback, before ctx clears.
-- The same callback is used by Space, number and the native mouse selector.
-- All records are snapshots of selected spans; no reading is guessed from text.
function M.selected(ctx, committed, language, navigation)
  local raw = ctx.input
  local body_start
  if raw:sub(1, 2) == 'qQ' then body_start = 2
  elseif raw:match("^q[a-z' ]*$") then body_start = 1
  else return {} end
  local allowed, result = {}, {}
  for _, entry in ipairs(committed) do
    if entry.custom_code == entry.text .. ' ' then allowed[entry.text] = true end
  end
  for _, segment in ipairs(ctx.composition:toSegmentation():get_segments()) do
    local candidate = segment:get_selected_candidate()
    local phrase = candidate and candidate:get_genuine():to_phrase()
    -- A bracket pick consumed a word's spelling to select one character.
    if phrase and phrase.type ~= 'jp_bracket_character'
        and phrase.lang_name == language and allowed[phrase.entry.text]
        and phrase.entry.custom_code == phrase.entry.text .. ' ' then
      local spans = navigation and navigation.candidates[
        candidate.text .. '\t' .. candidate._end]
      local record = M.capture(raw, body_start, candidate, spans and spans.vertices)
      if record then
        record.text = phrase.entry.text
        result[#result + 1] = record
      end
    end
  end
  return result
end

return M
