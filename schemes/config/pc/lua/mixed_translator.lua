-- curated mixed phrases. One native identity serves full and abbreviated codes.
local M = {}
local data = require('mixed_data')

local function matches(input, item)
  if input:sub(1, #item.prefix) ~= item.prefix then return end
  local stop = #item.prefix
  while input:sub(stop + 1, stop + 1) == "'" do stop = stop + 1 end
  local positions = {[stop]=0}
  for _, syllable in ipairs(item.syllables) do
    local following = {}
    for offset, kind in pairs(positions) do
      for length = 1, #syllable do
        if input:sub(offset + 1, offset + length) == syllable:sub(1, length) then
          local ending = offset + length
          while input:sub(ending + 1, ending + 1) == "'" do ending = ending + 1 end
          local next_kind = math.max(kind, length == #syllable and 0 or 1)
          following[ending] = math.min(following[ending] or 2, next_kind)
        end
      end
    end
    positions = following
  end
  -- As for Chinese phrases, a complete word may precede a still-unselected tail.
  local ending, kind
  for offset, matched in pairs(positions) do
    if not ending or offset > ending then ending, kind = offset, matched end
  end
  return ending, kind
end

-- Let a preceding Chinese phrase preserve a recognized mixed-word tail.
function M.continuation_cost(input, position, costs)
  local best
  for _, item in ipairs(data) do
    local ending, kind = matches(input:sub(position), item)
    local tail = ending and costs[position + ending]
    if tail then best = math.min(best or math.huge, kind + tail) end
  end
  return best
end

function M.init(env)
  env.mem = Memory(env.engine, env.engine.schema, 'mixed_native')
  env.mem:memorize(function(commit)
    for _, entry in ipairs(commit:get()) do env.mem:update_userdict(entry, 1, '') end
    return true
  end)
end

function M.fini(env)
  env.mem:disconnect()
  env.mem = nil
end

local function entry_for(env, item)
  if env.mem:user_lookup(item.code, false) then
    for entry in env.mem:iter_user() do
      if entry.text == item.text then return entry, true end
    end
  end
  if env.mem:dict_lookup(item.code, false, 0) then
    for entry in env.mem:iter_dict() do
      if entry.text == item.text then return entry, false end
    end
  end
  error('Mixed phrase missing from its native dictionary: ' .. item.code)
end

function M.func(input, seg, env)
  env.mem:finish_session()
  if not input:match("^[A-Za-z']+$") then return end
  local items, lower = {}, input:lower()
  for _, item in ipairs(data) do
    local ending, kind = matches(lower, item)
    if ending then
      local entry, learned = entry_for(env, item)
      local text = item.text
      local literal = input:sub(1, #item.prefix)
      if #literal > 1 and literal == literal:upper() then text = text:upper() end
      local phrase = Phrase(env.mem, 'research_mixed', seg.start, seg.start + ending, entry)
      phrase.preedit = input:sub(1, ending)
      local shown = ShadowCandidate(phrase:toCandidate(), 'research_mixed', text,
                                    kind == 0 and '完整词' or '简拼')
      shown.quality = (learned and (0.5 + math.exp(entry.weight))
          or (-1 + math.log(1 + item.weight) / 1000)) - kind * 0.1
      items[#items + 1] = shown
    end
  end
  table.sort(items, function(a, b)
    if a._end ~= b._end then return a._end > b._end end
    if a.quality ~= b.quality then return a.quality > b.quality end
    return a.text < b.text
  end)
  for _, candidate in ipairs(items) do yield(candidate) end
end

return M
