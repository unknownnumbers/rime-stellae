-- Romaji word lookup and small-kana drafts. Matching stays in Rime's native
-- dictionary; q/v retain one jp_family Memory. No annotation enters the text.
local M = {}
local jp = require('jp_v')
local family, memory
local reverse
local function lookup_codes(text)
  if not reverse then reverse = ReverseLookup('jp_q_lookup') end
  return reverse:lookup(text)
end
M.lookup_codes = lookup_codes

function M.parse(ctx, start)
  local raw = ctx.input
  local prefix = raw:sub(1, 2)
  if prefix == 'qQ' or prefix == 'xX' then
    return {raw=raw, prefix=prefix, prefix_len=2, body_start=2,
      body_end=#raw, body=raw:sub(3), held=true, small=prefix == 'xX'}
  elseif raw:match("^q[a-z' ]*$") then
    if start == nil then start = ctx.composition:empty() and 0 or ctx.composition:back().start end
    if start == 0 then
      return {raw=raw, prefix='q', prefix_len=1, body_start=1,
        body_end=#raw, body=raw:sub(2), held=false, small=false}
    end
  end
end

local function init(env)
  family, memory = require('jp_family'), require('jp_memory')
  env.owner = memory.acquire(env.engine)
end
local function fini(env)
  memory.release(env.owner)
  env.owner = nil
end

M.segmentor = {}
function M.segmentor.func(segmentation, env)
  local ctx = env.engine.context
  local state = not ctx:get_option('ascii_mode') and M.parse(ctx)
  -- Single-q retains the original native Kana composition and old q codes.
  if not state or not state.held then return true end
  local start = segmentation:get_current_start_position()
  segmentation.input = ctx.input
  if start >= #ctx.input then return true end
  local seg = Segment(start, #ctx.input)
  seg.tags = Set({'jp_query', 'raw_preedit'})
  segmentation:add_segment(seg)
  return false
end

M.translator = {}
M.translator.init = init
function M.translator.fini(env)
  env.native, env.small_native = nil, nil
  collectgarbage('collect')
  env.lookup_schema, env.small_schema = nil, nil
  fini(env)
end
local function native_query(query, seg, env)
  if not env.native then
    env.lookup_schema = Schema('jp_q_lookup')
    env.native = assert(Component.Translator(env.engine, env.lookup_schema, '',
      'script_translator@translator'))
  end
  return env.native:query(query, seg)
end
function M.translator.func(input, seg, env)
  local ctx = env.engine.context
  local state = not ctx:get_option('ascii_mode') and M.parse(ctx, seg.start)
  if not state then return end
  local start = math.max(seg.start, state.body_start)
  local body = state.raw:sub(start + 1)
  if body == '' then return end
  if state.small then
    if not body:match("^[a-zA-Z' ]+$") then return end
    if not env.small_native then
      env.small_schema = Schema('jp_small_lookup')
      env.small_native = assert(Component.Translator(env.engine, env.small_schema, '',
        'script_translator@translator'))
    end
    local query_seg = Segment(start, #state.raw)
    query_seg.tags = Set({'abc'})
    local translation = env.small_native:query(body, query_seg)
    if not translation then return end
    for original in translation:iter() do
      local candidate = ShadowCandidate(original, 'jp_small', original.text, '')
      candidate.start = seg.start
      candidate.preedit = state.raw:sub(seg.start + 1, candidate._end)
      jp.remember_navigation(ctx, candidate, original, state)
      yield(candidate)
    end
    return
  end
  if not body:match("^[a-zA-Z' ]+$") then return end
  local native_seg = Segment(start, #state.raw)
  native_seg.tags = Set({'abc'})
  local translated = native_query(body:lower(), native_seg, env)
  if not translated then return end
  for candidate in translated:iter() do
    if candidate._end > start then
      local function show(original, vertices)
        local wrapped = memory.wrap(env.owner, original, original.text,
          jp.variant_metadata(original.text), 'jp_q_form')
        wrapped.start = seg.start
        wrapped.preedit = state.raw:sub(seg.start + 1, wrapped._end)
        jp.remember_navigation(ctx, wrapped, original, state, vertices)
        yield(wrapped)
      end
      if candidate:get_genuine():to_sentence() then
        local next_sequence = require('jp_sequence').iter(candidate, body:lower(), native_seg,
          function(spelling, part_seg) return native_query(spelling, part_seg, env) end)
        for original, vertices in next_sequence do show(original, vertices) end
      else show(candidate) end
    end
  end
end

local function match_end(text, query)
  local best
  for code in lookup_codes(text):gmatch('%S+') do
    if query:sub(1, #code) == code then
      local ending = #code
      while query:sub(ending + 1, ending + 1):match("[' ]") do ending = ending + 1 end
      if not best or ending > best then best = ending end
    end
  end
  return best
end

function M.members(text, raw)
  if not family.is_han(text) then return {text} end
  local body = raw:sub(raw:sub(1, 1) == 'q' and 2 or 1):lower()
  local result = {}
  for _, member in ipairs(family.members(text)) do
    if family.matches_q(member, raw) or match_end(member, body) == #body then
      result[#result + 1] = member
    end
  end
  return result
end

M.filter = {}
M.filter.init = init
M.filter.fini = fini
function M.filter.func(input, env)
  local ctx = env.engine.context
  local state = not ctx:get_option('ascii_mode') and M.parse(ctx)
  if not state or state.small or not state.held then
    for candidate in input:iter() do yield(candidate) end
    return
  end
  memory.begin_query(env.owner)
  local start = math.max(state.body_start, ctx.composition:back().start)
  local query = state.raw:sub(start + 1):lower()
  local learned = {}
  for _, entry in ipairs(memory.learned(env.owner)) do
    local ending, vertices = match_end(entry.text, query)
    for _, record in ipairs(memory.readings(env.owner, entry.text)) do
      local stop, stops = require('jp_reading_metadata').match(record, query)
      if stop and (not ending or stop >= ending) then ending, vertices = stop, stops end
    end
    if ending then
      local original = Candidate('jp_q_learned', ctx.composition:back().start,
        start + ending, entry.text, '')
      original.preedit = state.raw:sub(original.start + 1, original._end)
      local absolute = {}
      for _, vertex in ipairs(vertices or {0, ending}) do absolute[#absolute + 1] = start + vertex end
      local shown = memory.wrap(env.owner, original, entry.text,
        jp.variant_metadata(entry.text), 'jp_q_form')
      jp.remember_navigation(ctx, shown, original, state, absolute)
      learned[#learned + 1] = {candidate=shown, score=memory.score(env.owner, entry.text)}
    end
  end
  table.sort(learned, function(a,b)
    if a.candidate._end ~= b.candidate._end then return a.candidate._end > b.candidate._end end
    if a.score ~= b.score then return a.score > b.score end
    return a.candidate.text < b.candidate.text
  end)
  local next_native, iterator = input:iter()
  local native
  local function advance()
    native = nil
    while true do
      local candidate = next_native(iterator)
      if not candidate then return end
      if candidate.type == 'jp_q_form' then
        native = {candidate=candidate, score=memory.score(env.owner,candidate.text)}
        return
      end
    end
  end
  advance()
  local index, seen, rank = 1, {}, 0
  while native or learned[index] do
    local item, chosen = native, learned[index]
    local from_native = true
    if chosen and (not item or chosen.candidate._end > item.candidate._end
        or (chosen.candidate._end == item.candidate._end and chosen.score > item.score)) then
      item, index, from_native = chosen, index + 1, false
    end
    local candidate = item.candidate
    local identity = family.resolve(candidate.text) .. '\t' .. candidate._end
    if not seen[identity] then
      seen[identity] = true
      local raw = state.raw:sub(math.max(state.body_start,candidate.start)+1,candidate._end)
      local members = M.members(candidate.text, raw)
      if #members == 0 then members = {candidate.text} end
      for _, text in ipairs(members) do
        local shown = candidate
        if text ~= candidate.text then
          shown = memory.wrap(env.owner, candidate, text, jp.variant_metadata(text), 'jp_q_form')
          shown.start, shown._end, shown.preedit = candidate.start, candidate._end, candidate.preedit
          local navigation = jp.navigation(ctx)
          if navigation then
            navigation.candidates[text .. '\t' .. shown._end] =
              navigation.candidates[candidate.text .. '\t' .. candidate._end]
          end
        end
        rank = rank + 1
        shown.quality = 1000000 - rank
        yield(shown)
      end
    end
    if from_native then advance() end
  end
end

local function submit(ctx, candidate, text, env, learned)
  local state = M.parse(ctx, candidate.start)
  local before, prior = jp.selected_prefix(ctx, candidate.start)
  local tail = state.raw:sub(candidate._end + 1)
  if tail ~= '' and state.held then tail = state.prefix .. tail end
  env.engine:commit_text(before .. text)
  for _, word in ipairs(prior) do memory.learn(env.owner, word) end
  if learned then memory.learn(env.owner, learned) end
  ctx:clear()
  if tail ~= '' then ctx:push_input(tail) end
end

local nav = {[0x2c]='Up', [0x2e]='Down', [0x2d]='Page_Up', [0x3d]='Page_Down'}
M.processor = {}
function M.processor.init(env)
  init(env)
  env.selector = assert(Component.Processor(env.engine, '', 'selector'))
end
function M.processor.fini(env)
  env.selector = nil
  fini(env)
end
function M.processor.func(key, env)
  local ctx = env.engine.context
  if ctx:get_option('ascii_mode') or key:release() or key:alt() or key:super() then return 2 end
  local state = M.parse(ctx)
  if not state then return 2 end
  local owner = jp.navigation(ctx)
  if owner and jp.navigate_query(key, ctx, owner) then return 1 end
  local code = key.keycode
  if key:ctrl() then return 2 end
  if not key:shift() and nav[code] then
    if ctx:has_menu() then env.selector:process_key_event(KeyEvent(nav[code])) end
    return 1
  end
  if not key:shift() and (code == 0x5b or code == 0x5d) and not state.small then
    local candidate = ctx:get_selected_candidate()
    local first, last
    if candidate then
      for _, cp in utf8.codes(candidate.text) do
        if (cp >= 0x3400 and cp <= 0x9fff) or cp >= 0x20000 then
          first = first or cp; last = cp
        end
      end
    end
    if first then
      local text = utf8.char(code == 0x5b and first or last)
      if state.held and candidate._end < state.body_end then
        jp.confirm_bracket(ctx, candidate, text, text, env.owner)
      else
        submit(ctx, candidate, text, env, text)
      end
    end
    return 1
  end
  if state.held and not key:shift() and (code == 0xff0d or code == 0xff8d) then
    local start = math.max(state.body_start, ctx.composition:back().start)
    local text = jp.selected_prefix(ctx, start) .. state.raw:sub(start + 1)
    if text ~= '' then env.engine:commit_text(text) end
    ctx:clear()
    return 1
  end
  if state.held and code == 0x20 and not ctx:has_menu() then return 1 end
  if state.held and code >= 0x41 and code <= 0x7a and string.char(code):match('^[a-zA-Z]$') then
    ctx:push_input(string.char(code))
    return 1
  end
  return 2
end

-- Direct first/last-character commits use the same admission as native JP
-- phrases; only attested forms supplement the existing all-kanji gate.
function M.admitted(text)
  return lookup_codes(text) ~= ''
end
return M
