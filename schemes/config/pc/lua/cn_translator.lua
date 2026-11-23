-- Chinese candidate ordering: exact and extended queries share one native Memory owner.
local greek = require('pc_probe_greek_proxy')
local matcher = require('cn_match')
local forms = require('cn_forms')
local tolerance = require('cn_tolerance')
local normal_codec = require('cn_normal_codec')
local exact_spelling = require('cn_exact_spelling')
local english = require('en_indexed_translator')
local mixed = require('mixed_translator')
local M = {}
local native_boundary = require('cn_native_boundary')
local spacing = require('cn_preedit_spacing')
local orthography = require('cn_orthography')

local function is_greek(text)
  if utf8.len(text) ~= 1 then return false end
  local code = utf8.codepoint(text)
  return code >= 0x370 and code <= 0x3ff
end

local function is_single_hanzi(text)
  if utf8.len(text) ~= 1 then return false end
  local cp = utf8.codepoint(text)
  return cp == 0x3007 or (cp >= 0x3400 and cp <= 0x4dbf)
      or (cp >= 0x4e00 and cp <= 0x9fff) or (cp >= 0xf900 and cp <= 0xfaff)
      or (cp >= 0x20000 and cp <= 0x2fa1f) or (cp >= 0x30000 and cp <= 0x3347f)
end

local function is_completion(candidate)
  -- Chinese lanes retain native Phrases, and completion keeps its native type.
  return candidate.type == 'completion'
end

local function classify(candidate, input, seg, env, cache)
  local ending = candidate._end - seg.start
  if cache.exact_tail_cost and ending <= cache.exact_plan.exact_end
      and not cache.exact_tail_cost[ending + 1] then return nil end
  local phrase = candidate:get_genuine():to_phrase()
  if not phrase then return nil end
  local completion = phrase.type == 'completion'
  if completion and (not env.allow_word_completion
      or (cache.exact_plan and cache.exact_plan.exact_end
        and not input:sub(math.max(cache.exact_plan.exact_end + 1,
          candidate.start - seg.start + 1), ending):find('[a-z]'))) then
    return nil
  end
  local syllables = env.decoder:decode(phrase.code)
  local code = table.concat(syllables, ' ')
  local matched_size
  -- Native metadata alone defines the typed prefix. Keep the original full
  -- code/entry and Phrase owner for commit and canonical learning.
  if completion then
    if env.use_stock_word_completion then
      if cache.exact_plan then
        -- Stock does not expose the native matched syllable count. Verify a
        -- valid canonical prefix instead, without changing the native Phrase.
        local base = candidate.start - seg.start
        local raw = input:sub(base + 1, ending)
        local _, letters = raw:gsub('[a-z]', '')
        local prefix, matched = {}, false
        cache.stock_completion = cache.stock_completion or {}
        for size = 1, math.min(#syllables - 1, letters) do
          prefix[size] = syllables[size]
          local key = base .. ':' .. raw .. '\t' .. table.concat(prefix, ' ')
          local valid = cache.stock_completion[key]
          if valid == nil then
            local kind = matcher.classify(raw, prefix, forms, input,
              env.extra_forms, base, cache.exact_plan)
            valid = kind ~= nil and kind < 2
            cache.stock_completion[key] = valid
          end
          if valid then matched = true; break end
        end
        if not matched then return nil end
      end
      return 1, 0, code, true
    end
    matched_size = phrase.matching_code_size
    if type(matched_size) ~= 'number' or matched_size < 1
        or matched_size >= #syllables or matched_size % 1 ~= 0 then return nil end
    for i = #syllables, matched_size + 1, -1 do syllables[i] = nil end
  end
  local raw = input:sub(candidate.start - seg.start + 1, candidate._end - seg.start)
  local key = raw .. '\t' .. code
  if completion then key = key .. '\tcompletion\t' .. matched_size end
  local result = cache[key]
  if result == nil then
    local kind, edits = matcher.classify(raw, syllables, forms, input, env.extra_forms,
      candidate.start - seg.start, cache.exact_plan)
    result = kind and {kind, edits, code, completion} or false
    cache[key] = result
  end
  if result then return result[1], result[2], result[3], result[4] end
end

-- Query-local complete syllable endpoints, reused for ranking and boundaries.
local function complete_ends(candidate, input, seg, env, cache, code, transposition)
  local offset = candidate.start - seg.start
  local key = offset .. ':' .. tostring(transposition ~= false) .. ':' .. code
  cache.complete_ends = cache.complete_ends or {}
  local ends = cache.complete_ends[key]
  if not ends then
    local syllables = {}
    for syllable in code:gmatch('%S+') do syllables[#syllables+1]=syllable end
    ends = matcher.full_correction_ends(input:sub(offset+1),syllables,env.full_forms,
      env.neighbor_substitution,env.missing_letter,transposition,cache.exact_plan,offset)
    cache.complete_ends[key]=ends
  end
  return ends,offset
end

local function full_correction_candidate(candidate,input,seg,env,cache,code)
  if cache.reliable and cache.reliable[candidate] then return true end
  local ends,offset=complete_ends(candidate,input,seg,env,cache,code,false)
  return ends[candidate._end-seg.start-offset] ~= nil
end

local function complete_boundary(candidate,input,seg,env,cache,code,tail_cost,allow_extension)
  local ends,offset=complete_ends(candidate,input,seg,env,cache,code)
  local stop=candidate._end-seg.start
  local best,best_edits,best_tail
  for ending,path in pairs(ends) do
    ending=ending+offset
    local tail=tail_cost[ending+1]
    if (ending<=stop or allow_extension) and tail then
      if not best or path.edits<best_edits or
          (path.edits==best_edits and ending==#input and best~=#input) or
          (path.edits==best_edits and best~=#input and
            (tail<best_tail or (tail==best_tail and ending<best))) then
        best,best_edits,best_tail=ending,path.edits,tail
      end
    end
  end
  return best,best_edits
end

local function before(a, b)
  return a.score > b.score or (a.score == b.score and a.order < b.order)
end

local function push(heap, item)
  local i = #heap + 1
  while i > 1 do
    local parent = i // 2
    if not before(item, heap[parent]) then break end
    heap[i], i = heap[parent], parent
  end
  heap[i] = item
end

local function pop(heap)
  local item, last = heap[1], table.remove(heap)
  if #heap > 0 then
    local i = 1
    while i * 2 <= #heap do
      local child = i * 2
      if child < #heap and before(heap[child + 1], heap[child]) then child = child + 1 end
      if not before(heap[child], last) then break end
      heap[i], i = heap[child], child
    end
    heap[i] = last
  end
  item.candidate.quality = item.score
  yield(item.candidate)
end

-- Raw candidates can move to an earlier normal boundary. Keep that pending
-- queue by consumed end, then native quality; insertion order breaks ties.
local function pending_before(a, b)
  if a.ending ~= b.ending then return a.ending > b.ending end
  if a.score ~= b.score then return a.score > b.score end
  return a.order < b.order
end

local function pending_push(heap, candidate, order)
  local item = {candidate=candidate, ending=candidate._end,
                score=candidate.quality, order=order}
  local i = #heap + 1
  while i > 1 do
    local parent = i // 2
    if not pending_before(item, heap[parent]) then break end
    heap[i], i = heap[parent], parent
  end
  heap[i] = item
end

local function pending_pop(heap)
  local item, last = heap[1], table.remove(heap)
  if #heap > 0 then
    local i = 1
    while i * 2 <= #heap do
      local child = i * 2
      if child < #heap and pending_before(heap[child + 1], heap[child]) then
        child = child + 1
      end
      if not pending_before(heap[child], last) then break end
      heap[i], i = heap[child], child
    end
    heap[i] = last
  end
  return item.candidate
end

local function normal_tail_cost(input, env, cache)
  return spacing.normal_tail_cost(input, env, cache)
end

local function boundary_query(input, seg, env, cache, query_input)
  local native_input = query_input or (cache.exact_plan and
    exact_spelling.encode(input, nil, normal_codec.encode, cache.exact_plan)) or input
  local native = env.native:query(native_input, seg)
  if not native then return end
  local tail_cost = normal_tail_cost(input, env, cache)
  local word_ends, pending, pending_order = {}, {}, 0
  for candidate in native:iter() do
    while #pending > 0 and pending[1].ending >= candidate._end do
      yield(pending_pop(pending))
    end
    -- Completion is admitted only by the existing normal lane, before any
    -- complete-code matching, boundary repair or correction promotion.
    if not is_completion(candidate) then
    local stop, preferred, preferred_kind, preferred_edits = candidate._end - seg.start
    local kind, edits, code
    kind, edits, code = classify(candidate, input, seg, env, cache)
    local aligned_end,aligned_edits
    local reliable = kind==2 and query_input and
      full_correction_candidate(candidate,input,seg,env,cache,code)
    -- The complete graph repairs its own short normal prefix. The raw
    -- graph only needs this work for actual corrections, not every ordinary
    -- prefix in a long mixed draft.
    if kind==2 or (query_input and kind==1) then
      aligned_end,aligned_edits=complete_boundary(candidate,input,seg,env,cache,code,tail_cost,true)
      if aligned_end and aligned_end~=stop then
        local syllables=env.decoder:decode(candidate:get_genuine():to_phrase().code)
        if not native_boundary.try(candidate,seg.start+aligned_end,#syllables) then
          aligned_end=nil
        end
      end
    end
    if reliable then
      cache.reliable=cache.reliable or {}
      cache.reliable[candidate]=true
    end
    if aligned_end and aligned_end~=stop then
      preferred,preferred_kind,preferred_edits=aligned_end,2,aligned_edits
    elseif kind == 2 and not aligned_end then
      local ends = word_ends[code]
      if not ends then
        local syllables = env.decoder:decode(candidate:get_genuine():to_phrase().code)
        ends = matcher.prefix_ends(input, syllables, forms, env.extra_forms, cache.exact_plan)
        word_ends[code] = ends
      end
      for ending, matched in pairs(ends) do
        local tail = tail_cost[ending + 1]
        -- A normal interpretation keeps its next syllable even when that
        -- continuation contains more abbreviations. Apply this to whole raw
        -- corrections too, so learned words cannot bypass the same boundary.
        local normal = matched[1] < 2
        local fewer_errors = matched[2] < edits and tail
            and tail <= (tail_cost[stop + 1] or math.huge)
        if ending < stop and tail and (normal or fewer_errors)
            and (not preferred or matched[1] < preferred_kind
                 or (matched[1] == preferred_kind and matched[2] < preferred_edits)
                 or (matched[1] == preferred_kind and matched[2] == preferred_edits
                     and ending > preferred)) then
          preferred, preferred_kind, preferred_edits = ending, matched[1], matched[2]
        end
      end
    end
    if preferred then
      -- Keep the native Phrase, dictionary identity and syllabifier. Its spans
      -- are recomputed from the same graph using the corrected end position.
      candidate._end = seg.start + preferred
      if preferred_kind == 0 then candidate.type = 'cn_full' end
      local vertices, preedit = candidate:spans().vertices, {}
      for i = 2, #vertices do
        preedit[#preedit + 1] = input:sub(vertices[i - 1] - seg.start + 1,
                                        vertices[i] - seg.start)
      end
      candidate.preedit = env.preedit_format:apply(table.concat(preedit, ' '), true)
      pending_order = pending_order + 1
      pending_push(pending, candidate, pending_order)
    else yield(candidate) end
    end
  end
  while #pending > 0 do yield(pending_pop(pending)) end
end

-- Normal matches retain their native graph, code, spans and consumed range.
local function normal_query(input, seg, env, cache)
  local query = cache.exact_plan and exact_spelling.encode(input, normal_codec.encode, normal_codec.encode, cache.exact_plan)
    or normal_codec.encode(input)
  local native = env.native:query(query, seg)
  if not native then return end
  local ordinary = input:match("^([a-z]+)[' ]*$")
  local skip_single = ordinary and #ordinary < 3 and env.normal_spellings[ordinary] == 0
  for candidate in native:iter() do
    if not (skip_single and is_single_hanzi(candidate.text)) then
      local kind, _, _, completion = classify(candidate, input, seg, env, cache)
      if kind and kind < 2 then
        if completion and env.use_stock_word_completion then
          local preedit = normal_codec.decode(candidate.preedit)
          if preedit == '' then
            preedit = input:sub(candidate.start - seg.start + 1, candidate._end - seg.start)
          end
          candidate.preedit = env.preedit_format:apply(preedit, true)
        else
          local vertices, preedit = candidate:spans().vertices, {}
          for i = 2, #vertices do
            preedit[#preedit + 1] = input:sub(vertices[i - 1] - seg.start + 1,
                                            vertices[i] - seg.start)
          end
          candidate.preedit = env.preedit_format:apply(table.concat(preedit, ' '), true)
        end
        if kind == 0 and not completion then candidate.type = 'cn_full' end
        yield(candidate)
      end
    end
  end
end

local function chinese_query(input, seg, env, exact, cache, normal_only)
  if not input:match("^[a-z' ]+$")
      and not (cache.exact_plan and input:match('^[a-z\'"; ]+$')) then return end
  -- Decide spelling eligibility from the whole queried input.
  -- qi keeps qi characters; qijin still permits qian+jing as a normal prefix.
  local ordinary = input:match("^([a-z]+)[' ]*$")
  local single_full_input = ordinary and env.normal_spellings[ordinary] == 0
  -- Below the three-letter correction threshold, this stream can only
  -- contain full spellings (served separately) or normal prefixes.
  -- excludes both single-Hanzi cases here; avoid decoding every one.
  local skip_single = not exact and single_full_input and #ordinary < 3
  -- The uppercase channel also contains complete-code correction aliases.
  -- They are internal queries; the actual context input remains untouched.
  local translation
  if exact then
    -- Confirmed spelling uses the ordinary graph without typo aliases. Free
    -- spelling keeps this lane's complete-code query and native ownership.
    local query = cache.exact_plan and
      exact_spelling.encode(input, string.upper, normal_codec.encode, cache.exact_plan) or input:upper()
    translation = Translation(boundary_query,input,seg,env,cache,query)
  elseif normal_only then translation = Translation(normal_query, input, seg, env, cache)
  else translation = Translation(boundary_query, input, seg, env, cache) end
  if not translation then return end
  local heap, span, base, order = {}, nil, math.huge, 0
  for candidate in translation:iter() do
    if not is_greek(candidate.text)
        and not (skip_single and is_single_hanzi(candidate.text)) then
      local kind, edits, code, completion = classify(candidate, input, seg, env, cache)
      local aligned = exact and kind==2 and
        full_correction_candidate(candidate,input,seg,env,cache,code)
      if aligned then
        -- Restrict new cold promotion to one complete R06/R07 operation and
        -- an actual dictionary phrase. Other paths stay in the raw stream.
        local genuine=candidate:get_genuine()
        aligned=genuine.type~='sentence' and (edits<=1 or genuine.type=='user_phrase')
      end
      -- A complete dictionary Phrase excluded from cold promotion can still
      -- supply its real boundary when the same word later wins a normal
      -- prefix slot. Retain only already visited objects, without advancing
      -- any iterator or introducing another query/learning owner.
      if exact and kind==2 and not aligned and candidate._end==seg.start+#input then
        local genuine=candidate:get_genuine()
        if genuine.type=='phrase' or genuine.type=='user_phrase' then
          local ends,offset=complete_ends(candidate,input,seg,env,cache,code)
          if ends[candidate._end-seg.start-offset] then
            cache.whole_boundaries=cache.whole_boundaries or {}
            local key=candidate.start..'\t'..code..'\t'..candidate.text
            candidate.preedit=env.preedit_format:apply(candidate.preedit:lower(),true)
            cache.whole_boundaries[key]=candidate
          end
        end
      end
      if kind and ((exact and (kind == 0 or aligned))
          or (normal_only and (completion or kind ~= 0 or candidate.type == 'cn_full'))
          or (not exact and not normal_only and (kind ~= 0 or candidate.type == 'cn_full')))
          and not (single_full_input and kind == 1 and is_single_hanzi(candidate.text)) then
        candidate.comment = ''
        if exact then
          candidate.preedit = env.preedit_format:apply(candidate.preedit:lower(), true)
          local genuine=candidate:get_genuine()
          local user=genuine.type=='user_phrase'
          -- Uppercase fuzzy entries already contain the native credibility.
          -- Remove the whole-graph normal/fuzzy offset; do not charge twice.
          candidate.quality=math.exp(genuine:to_phrase().entry.weight)
            + (user and 0.5 * (aligned and 0.5^edits or 1) or 0)
          if kind==0 then candidate.type='cn_full' end
          yield(candidate)
        elseif normal_only then
          if not completion then
            candidate.quality = candidate.quality - (kind == 2 and 0.05 * edits or 0)
          end
          yield(candidate)
        else
          if span ~= candidate._end then
            while #heap > 0 do pop(heap) end
            span, base = candidate._end, math.huge
          end
          -- Apply the edit cost even when every interpretation is a typo.
          -- Native order includes user-dictionary priority and is not strictly
          -- quality-sorted. Its decreasing envelope gives a safe lazy bound.
          base = math.min(base, candidate.quality)
          while #heap > 0 and heap[1].score >= base do pop(heap) end
          order = order + 1
          push(heap, {candidate=candidate, order=order,
                      score=base - (kind == 2 and 0.05 * edits or 0)})
        end
      end
    end
  end
  while #heap > 0 do pop(heap) end
end

-- These derived tables depend only on the loaded cn_forms module. Each env
-- holds the bundle while in use; the weak cache does not retain it on its own.
local spelling_tables = setmetatable({}, {__mode='v'})

local function initialize_spellings(env, schema)
  require('cn_boundaries')
  env.extra_forms = tolerance.from_config(schema.config)
  env.neighbor_substitution = schema.config:get_bool('cn_tolerance/neighbor_substitution') ~= false
  env.missing_letter = schema.config:get_bool('cn_tolerance/missing_letter') ~= false
  local shared = spelling_tables[1]
  if not shared then
    shared = {full_forms={}, normal_spellings={}, normal_max_length=0, full_spellings={}}
    for syllable, spellings in pairs(forms) do
      local complete = {}
      shared.full_forms[syllable] = complete
      for raw, kind in pairs(spellings.values) do
        if kind == 0 then
          shared.full_spellings[syllable] = raw
          complete[#complete + 1] = raw
        end
        if kind < 2 then
          shared.normal_spellings[raw] = math.min(shared.normal_spellings[raw] or 2, kind)
          shared.normal_max_length = math.max(shared.normal_max_length, #raw)
        end
      end
    end
    spelling_tables[1] = shared
  end
  env.cn_spelling_tables = shared
  env.full_forms, env.normal_spellings = shared.full_forms, shared.normal_spellings
  env.normal_max_length, env.full_spellings = shared.normal_max_length, shared.full_spellings
end

function M.init(env)
  env.allow_word_completion = true
  env.use_stock_word_completion = env.engine.schema.config:get_bool('translator/use_stock_word_completion') == true
  initialize_spellings(env, env.engine.schema)
  greek.init(env)
  env.decoder = Memory(env.engine, env.engine.schema, 'cn_decoder')
  env.preedit_format = Projection()
  env.preedit_format:load(env.engine.schema.config:get_list('translator/preedit_format'))
  env.symbol_env = {engine=env.engine, native=env.native, unified=true, only_greek=true,
    code_prefix=env.engine.schema.config:get_string('probe/greek_code_prefix') or ''}
  env.english_env = {engine=env.engine}
  english.init(env.english_env)
  env.mixed_env = {engine=env.engine}
  mixed.init(env.mixed_env)
  spacing.init(env)
end

-- Reuse this module's Chinese matching, merging and boundary logic in another
-- schema. This owns one isolated native translator; it does not initialize
-- symbol, English or mixed-word candidate streams or their learning owners.
function M.init_chinese(env, schema)
  env.lookup_schema = schema
  env.only_chinese = true
  env.allow_word_completion = false
  initialize_spellings(env, schema)
  env.native = assert(Component.Translator(env.engine, schema, '', 'script_translator@translator'))
  env.decoder = Memory(env.engine, schema, 'cn_decoder')
  env.preedit_format = Projection()
  env.preedit_format:load(schema.config:get_list('translator/preedit_format'))
end

function M.fini_chinese(env)
  env.native, env.decoder = nil, nil
  -- Native components release their references before the borrowed Schema.
  collectgarbage('collect')
  env.lookup_schema = nil
end

function M.fini(env)
  spacing.fini(env)
  mixed.fini(env.mixed_env)
  env.mixed_env = nil
  english.fini(env.english_env)
  env.english_env = nil
  env.decoder, env.symbol_env = nil, nil
  greek.fini(env)
end

local function learned_score(candidate, input, seg, env, cache)
  -- Native user completions already carry their learned score. Do not query
  -- the full canonical spelling again or add another learning owner/count.
  if is_completion(candidate) then return candidate.quality end
  if candidate.type == 'cn_full' or candidate:get_genuine().type ~= 'user_phrase' then
    return candidate.quality
  end
  local kind, edits, code = classify(candidate, input, seg, env, {})
  local key = code .. '\t' .. candidate.text
  local cached = cache[key]
  if cached ~= nil then
    return cached and (cached - (kind == 2 and 0.05 * edits or 0)) or candidate.quality
  end
  local spelling = {}
  for syllable in code:gmatch('%S+') do spelling[#spelling + 1] = env.full_spellings[syllable] end
  -- A fuzzy prism path discounts DictEntry.weight as well as candidate quality.
  -- Obtain the canonical native score, without another learning owner or a
  -- hand-maintained selection counter. Cache it for this one composition query.
  local native = env.native:query(table.concat(spelling, "'"):upper(), seg)
  local canonical_score
  if native then
    for entry in native:iter() do
      if entry.text == candidate.text and entry.type == 'user_phrase'
            and table.concat(env.decoder:decode(entry:to_phrase().code),' ')==code then
        canonical_score = entry.quality
        break
      end
    end
  end
  -- Cache the word's native score, not this particular path's edit penalty.
  cache[key] = canonical_score or false
  return canonical_score and (canonical_score - (kind == 2 and 0.05 * edits or 0))
                         or candidate.quality
end

local function unmarked_query(func, input, seg, env, plan, argument)
  local translation = Translation(func, input, seg, env, argument)
  if not translation then return end
  for candidate in translation:iter() do
    if exact_spelling.unmarked(plan, candidate.start - seg.start + 1,
                               candidate._end - seg.start) then yield(candidate) end
  end
end

local function long_single_letter_abbreviations(input, seg, env)
  if #input < 8 or env.only_chinese or seg.start ~= 0 or not input:match('^[a-z]+$') then
    return false
  end
  local ctx = env.engine.context
  if ctx.input ~= input or ctx.caret_pos ~= #input then return false end
  local normal = env.normal_spellings
  for pos = 1, #input do
    if normal[input:sub(pos, pos)] ~= 1 then return false end
    -- Keep the full query when this draft has a multi-letter normal spelling.
    for last = pos + 1, math.min(#input, pos + env.normal_max_length - 1) do
      if normal[input:sub(pos, last)] then return false end
    end
  end
  return true
end

function M.func(input, seg, env)
  if not env.only_chinese and env.engine.context:get_option('research_english') then
    english.func(input, seg, env.english_env, false)
    return
  end
  if not seg:has_tag('abc') then return end
  local current_sc = not env.only_chinese and env.engine.context:get_option('simplification')
  local match_cache, learned_scores = {}, {}
  if not env.only_chinese and env.engine.schema.schema_id == 'pc_research' then
    local suffix = env.engine.context.input:sub(seg.start + 1)
    if suffix:sub(1, #input) == input then match_cache.exact_plan = exact_spelling.parse(suffix) end
  end
  local plan = match_cache.exact_plan
  if plan and plan.invalid then return end
  local whole = plan and plan.whole
  if plan and plan.exact_end then
    local prefix = plan.input:sub(1, plan.exact_end)
    local full_cache = whole and input == prefix and match_cache
      or {exact_plan=exact_spelling.parse(prefix)}
    local full_cost = normal_tail_cost(prefix, env, full_cache)
    if not full_cost[1] then return end
    match_cache.exact_tail_cost = full_cost
  end
  local normal_only = long_single_letter_abbreviations(input, seg, env)
  local full_results = not normal_only and
    Translation(chinese_query, input, seg, env, true, match_cache) or nil
  local normal_results = not whole and Translation(chinese_query, input, seg, env, false, match_cache, true)
  local _, letter_count = input:gsub('[a-z]', '')
  local extended_results = not whole and not normal_only and letter_count >= 3 and
    Translation(chinese_query, input, seg, env, false, match_cache) or nil
  local greek_results, english_results, mixed_results
  if not whole and not env.only_chinese then
    if match_cache.exact_plan then
      greek_results = Translation(unmarked_query, greek.func, input, seg, env.symbol_env, match_cache.exact_plan)
      english_results = Translation(unmarked_query, english.func, input, seg, env.english_env, match_cache.exact_plan, true)
      mixed_results = Translation(unmarked_query, mixed.func, input, seg, env.mixed_env, match_cache.exact_plan)
    else
      greek_results = Translation(greek.func, input, seg, env.symbol_env)
      english_results = Translation(english.func, input, seg, env.english_env, true)
      mixed_results = Translation(mixed.func, input, seg, env.mixed_env)
    end
  end
  local fi, fs
  if full_results then fi, fs = full_results:iter() end
  local ni, ns
  if normal_results then ni, ns = normal_results:iter() end
  local xi, xs
  if extended_results then xi, xs = extended_results:iter() end
  local gi, gs, ei, es, mi, ms
  if greek_results then gi, gs = greek_results:iter() end
  if english_results then ei, es = english_results:iter() end
  if mixed_results then mi, ms = mixed_results:iter() end
  local f, n, x, g, e, m = fi and fi(fs), ni and ni(ns), xi and xi(xs),
    gi and gi(gs), ei and ei(es), mi and mi(ms)
  spacing.record(env,input,seg.start,match_cache)
  local complete_end = seg.start + #input
  local function normal_whole(value)
    return value and not is_completion(value) and value.start == seg.start
      and value._end == complete_end and classify(value,input,seg,env,match_cache)<2
  end
  local has_normal_complete = normal_whole(f) or normal_whole(n)
  -- Protect one already obtained whole normal head, once per query.
  -- Keep this separate from the existing static correction policy above.
  local completion_waits_for_normal = env.allow_word_completion and not env.use_stock_word_completion and
    (has_normal_complete or normal_whole(x))
  local previous_quality, seen = math.huge, {}

  local function prefer_cn(a, a_source, a_score, b, b_source, b_score)
    if not b then return true end
    local a_kind, _, a_code = classify(a, input, seg, env, match_cache)
    local b_kind, _, b_code = classify(b, input, seg, env, match_cache)
    -- Pick one real native boundary for the same word and reading. This does
    -- not change either candidate's score or its comparison with other words.
    if a.text == b.text and a_code == b_code and a._end ~= b._end then
      if a._end > b._end and
          full_correction_candidate(a, input, seg, env, match_cache, a_code) then
        return true
      elseif b._end > a._end and
          full_correction_candidate(b, input, seg, env, match_cache, b_code) then
        return false
      end
    end
    -- Complete Chinese remains protected at the same consumed range.
    if a._end == b._end then
      if a_kind == 0 and b_kind == 2 and b_source~='full' then return true end
      if a_kind == 2 and b_kind == 0 and a_source~='full' then return false end
    end
    -- The newly exposed reliable head competes by quality at the same
    -- coverage. A learned short prefix must not displace a normal whole
    -- sentence merely because the internal complete lane is visited first.
    if a._end~=b._end and
        ((a_source=='full' and a_kind==2 and b_kind<2) or
         (b_source=='full' and b_kind==2 and a_kind<2)) then
      return a._end>b._end
    end
    local a_correction = (a_source == 'extended' or a_source == 'full') and a_kind == 2
    local b_correction = (b_source == 'extended' or b_source == 'full') and b_kind == 2
    if has_normal_complete and (a_correction ~= b_correction) and
        not (a._end==b._end and (a_source=='full' or b_source=='full')) then
      local correction = a_correction and a or b
      if correction:get_genuine().type == 'user_phrase' then
        -- Use the existing canonical score; no new counters or permanent lock.
        if a_score ~= b_score then return a_score > b_score end
      else
        return not a_correction
      end
    end
    return a._end > b._end or (a._end == b._end and a_score > b_score)
  end

  while f or n or x or g or e or m do
    local candidate,source,score
    local normal_score=n and learned_score(n,input,seg,env,learned_scores)
    local extended_score=x and learned_score(x,input,seg,env,learned_scores)
    local full_score=f and f.quality
    if f and not is_completion(f) and classify(f,input,seg,env,match_cache)==0 then
      if e and f._end==e._end then full_score=math.max(full_score,e.quality) end
      if m and f._end==m._end then full_score=math.max(full_score,m.quality) end
    end
    local heads={{f,'full',full_score},{n,'normal',normal_score},{x,'extended',extended_score}}
    -- Elect the normal anchor first. Each correction must beat this same
    -- anchor: a short learned correction cannot indirectly admit a longer
    -- low-confidence correction which loses to the normal sentence itself.
    for _,head in ipairs(heads) do
      local value,lane,quality=head[1],head[2],head[3]
      if value and not is_completion(value) and classify(value,input,seg,env,match_cache)<2 and
          (not candidate or prefer_cn(value,lane,quality,candidate,source,score)) then
        candidate,source,score=value,lane,quality
      end
    end
    local anchor_candidate,anchor_source,anchor_score=candidate,source,score
    for _,head in ipairs(heads) do
      local value,lane,quality=head[1],head[2],head[3]
      if value and classify(value,input,seg,env,match_cache)==2 and
          (not anchor_candidate or prefer_cn(value,lane,quality,anchor_candidate,anchor_source,anchor_score)) and
          (candidate==anchor_candidate or not candidate or prefer_cn(value,lane,quality,candidate,source,score)) then
        candidate,source,score=value,lane,quality
      end
    end
    -- Completion challenges the ordinary winner only after every correction
    -- faced the same noncompletion anchor. Pairwise special rules here would
    -- either protect every normal word forever or reintroduce ordering cycles.
    if n and is_completion(n) and not completion_waits_for_normal and
        (not candidate or n._end > candidate._end
          or (n._end == candidate._end and normal_score > score)) then
      candidate,source,score=n,'normal',normal_score
    end
    -- Preserve the current symbol/English/mixed comparison outside this fix.
    if candidate and not is_completion(candidate)
        and classify(candidate, input, seg, env, match_cache) == 0 then
      if e and e._end == candidate._end then score = math.max(score, e.quality) end
      if m and m._end == candidate._end then score = math.max(score, m.quality) end
    end
    if g and (not candidate or g._end > candidate._end or (g._end == candidate._end and g.quality > score)) then
      candidate, source, score = g, 'symbol', g.quality
    end
    if e and (not candidate or e._end > candidate._end or (e._end == candidate._end and e.quality > score)) then
      candidate, source, score = e, 'english', e.quality
    end
    if m and (not candidate or m._end > candidate._end or (m._end == candidate._end and m.quality > score)) then
      candidate, source, score = m, 'mixed', m.quality
    end
    local duplicate_key, canonical_code
    if source == 'full' or source == 'normal' or source == 'extended' then
      local kind, edits, code, completion = classify(candidate, input, seg, env, match_cache)
      if not completion and kind==1 and candidate._end<complete_end and match_cache.whole_boundaries then
        local key=candidate.start..'\t'..code..'\t'..candidate.text
        local whole=match_cache.whole_boundaries[key]
        if whole then candidate=whole end
      end
      canonical_code = code
      duplicate_key = candidate.text
      candidate.comment = ''
      -- Only an ordinary whole normal result reaching final output/dedup
      -- releases the gate; an intervening symbol/English/mixed result cannot.
      if normal_whole(candidate) then completion_waits_for_normal = false end
    end
    if not duplicate_key or not seen[duplicate_key] then
      if duplicate_key then seen[duplicate_key] = true end
      candidate.quality = math.min(score, previous_quality - 0.000001)
      previous_quality = candidate.quality
      if canonical_code and not env.only_chinese then
        candidate = orthography.apply(candidate, canonical_code, current_sc, candidate._end == seg._end)
      end
      if canonical_code and match_cache.exact_plan then
        local vertices, preedit = candidate:spans().vertices, {}
        for index = 2, #vertices do
          preedit[#preedit + 1] = input:sub(vertices[index-1] - seg.start + 1,
                                           vertices[index] - seg.start)
        end
        candidate.preedit = env.preedit_format:apply(table.concat(preedit, ' '), true)
      end
      yield(candidate)
      if canonical_code and not env.only_chinese and not current_sc and not is_completion(candidate) then
        local text = orthography.tc_alias(candidate, canonical_code)
        if text and not seen[text] then
          seen[text] = true
          local alias = ShadowCandidate(candidate, candidate.type, text, candidate.comment)
          alias.preedit = candidate.preedit
          alias.quality = previous_quality - 0.000001
          previous_quality = alias.quality
          yield(alias)
        end
      end
    end
    if source == 'full' then f = fi(fs)
    elseif source == 'normal' then n = ni(ns)
    elseif source == 'extended' then x = xi(xs)
    elseif source == 'symbol' then g = gi(gs)
    elseif source == 'english' then e = ei(es)
    else m = mi(ms) end
  end
end

function M.query_chinese(input, seg, env)
  M.func(input, seg, env)
end

return M
