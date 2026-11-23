-- Japanese-use Kanji lookup. Raw control syntax is parsed afresh on each query.
-- The native dictionary owns the spelling graph; one JP word-family Memory
-- owns Hanzi learning. Presentation annotations are never learned as text.
local M = {}
local select_hanzi = require('select_hanzi')
local bracket_kind = 'jp_bracket_character'
local kana_tail_kind = 'jp_v_kana_tail'

-- Keep only spelling vertices, not the learnable native Phrase. Components
-- have separate env tables; this context-owned handle joins their lifetimes.
local navigation_owners, navigation_serial = {}, 0
local function remember_navigation(ctx, shown, original, state, vertices)
  local owner = navigation_owners[ctx:get_property('jp_v_navigation_owner')]
  if not owner then return end
  if owner.raw ~= ctx.input then
    owner.raw, owner.candidates, owner.moving = ctx.input, {}, nil
  end
  local spans = Spans()
  spans:add_vertex(shown.start)
  for _, vertex in ipairs(vertices or original:spans().vertices) do
    if vertex > state.body_start then
      spans:add_vertex(vertex == state.body_end and #state.raw or vertex)
    end
  end
  spans:add_vertex(#state.raw)
  owner.candidates[shown.text .. '\t' .. shown._end] = spans
end
local family, memory, learned_match
local function shared_init(env)
  family, memory = require('jp_family'), require('jp_memory')
  env.jp_owner = memory.acquire(env.engine)
end
local function shared_fini(env)
  memory.release(env.jp_owner)
  env.jp_owner = nil
end

local function navigate_query(key, ctx, owner)
  local code, word = key.keycode, key:ctrl() or key:shift()
  local left = code == 0xff51 or code == 0xff96
  local right = code == 0xff53 or code == 0xff98
  local tab = code == 0xff09 or code == 0xfe20
  if not (left or right or tab) then return false end
  if key:ctrl() and key:shift() then return false end
  if key:ctrl() and (tab or code == 0xff96 or code == 0xff98) then return false end
  local caret, ending = ctx.caret_pos, #ctx.input
  local confirmed = 0
  for _, seg in ipairs(ctx.composition:toSegmentation():get_segments()) do
    if seg.status ~= 'kSelected' and seg.status ~= 'kConfirmed' then break end
    confirmed = seg._end
  end
  if not owner.moving then
    local candidate = ctx:get_selected_candidate()
    owner.moving = candidate and owner.candidates[candidate.text .. '\t' .. candidate._end] or Spans()
    owner.moving:add_span(0, ending)
  end
  local spans, target = owner.moving, caret
  if tab then
    if key:shift() or code == 0xfe20 then
      target = caret == 0 and ending or spans:previous_stop(caret)
      if target < confirmed then target = ending end
    else target = spans:next_stop(caret == ending and confirmed or caret) end
  elseif left then
    if word or (code == 0xff51 and spans.count > 1 and spans:has_vertex(caret)) then
      target = caret == 0 and ending or spans:previous_stop(caret)
      if word and target < confirmed then target = ending end
    else target = caret == 0 and ending or caret - 1 end
  elseif right then
    if word then target = spans:next_stop(caret == ending and confirmed or caret)
    else target = caret == ending and 0 or caret + 1 end
  end
  ctx.caret_pos = target
  return true
end
local metadata
local function data()
  if not metadata then metadata = require('jp_v_data') end
  return metadata
end

local function kind(candidate)
  return candidate and (candidate.type:match('^jp_v') ~= nil
    or candidate.type == bracket_kind
    or candidate:get_genuine().type:match('^jp_v') ~= nil)
end

local function single_query(raw)
  -- The old dictionary's only v-led Kana code is vu. Preserve its continuation
  -- as well (e.g. vu+na); other lowercase v+code syntax belongs to the lookup.
  -- Also identify an empty-menu query so Ctrl+Return cannot fall through to
  -- native script submission and leak its control prefix.
  return raw:match("^v[a-z' ]*$") ~= nil and raw:sub(1, 2) ~= 'vu'
end

function M.parse(ctx, start)
  local raw = ctx.input
  if raw:sub(1, 2) == 'vV' then
    local marker = #raw > 2 and raw:sub(-1) or ''
    local closed = marker == 'v' or marker == 'V'
    local finish = #raw - (closed and 1 or 0)
    return {active=true, held=true, raw=raw, prefix_len=2, body_start=2,
      body_end=finish, body=raw:sub(3, finish), closed=closed,
      marker=closed and marker or '', mode=marker == 'V' and 'word' or 'char'}
  end
  if not single_query(raw) then return end
  -- Single v owns only the initial lookup segment. Once selected, the
  -- remaining draft is handled by the ordinary Japanese speller.
  if start == nil then start = ctx.composition:empty() and 0 or ctx.composition:back().start end
  if start ~= 0 then return end
  return {active=true, held=false, raw=raw, prefix_len=1, body_start=1,
    body_end=#raw, body=raw:sub(2), closed=false, marker='', mode='char'}
end

local function han(cp)
  return cp == 0x3007 or (cp >= 0x3400 and cp <= 0x4dbf)
    or (cp >= 0x4e00 and cp <= 0x9fff) or (cp >= 0xf900 and cp <= 0xfaff)
    or (cp >= 0x20000 and cp <= 0x2fa1f) or (cp >= 0x30000 and cp <= 0x3347f)
end

function M.reading_parts(candidate)
  if candidate.type ~= kana_tail_kind then return candidate.text, '' end
  for position, cp in utf8.codes(candidate.text) do
    if not han(cp) then return candidate.text:sub(1, position - 1), candidate.text:sub(position) end
  end
  return candidate.text, ''
end

local function reading_value(values)
  return values and #values > 0 and table.concat(values, '／') or '*讀音未收錄'
end

local function variant_label(text)
  local variants = {}
  for _, cp in utf8.codes(text) do
    local record = data().get_character(utf8.char(cp))
    if record and record.variant and record.variant ~= '' then variants[record.variant] = true end
  end
  local labels = {}
  if variants['舊'] then labels[#labels + 1] = '舊' end
  if variants['異'] then labels[#labels + 1] = '異' end
  return table.concat(labels, '／')
end

local function variant_metadata(text)
  local entries, index = {}, 0
  local labels = {['舊']='旧', ['異']='異'}
  for _, cp in utf8.codes(text) do
    local record = data().get_character(utf8.char(cp))
    local label = record and labels[record.variant]
    if label then entries[#entries + 1] = index .. '=' .. label end
    index = index + 1
  end
  return #entries > 0 and ('[jp:' .. table.concat(entries, ',') .. ']') or ''
end

function M.known_word(text)
  local readings = data().get_word((family or require('jp_family')).resolve(text))
  return readings ~= nil and #readings > 0
end

function M.describe(text, mode, group)
  local reference, commit = {}, {}
  local kun_reference, on_reference = {}, {}
  if mode == 'word' then
    local readings = data().get_word(text)
    local value = readings and #readings > 0 and table.concat(readings, '／')
      or '*整詞讀音未收錄'
    reference[1], commit[1] = value, text .. ' (' .. value .. ')'
  else
    for _, cp in utf8.codes(text) do
      local character = utf8.char(cp)
      local record = data().get_character(character)
      local kun = reading_value(record and record.kun_readings)
      local on = reading_value(record and record.on_readings)
      kun_reference[#kun_reference + 1], on_reference[#on_reference + 1] = kun, on
      local value = group == 'kun' and kun or group == 'on' and on
        or reading_value(record and record.readings)
      reference[#reference + 1] = value
      commit[#commit + 1] = character .. ' (' .. value .. ')'
    end
  end
  local variant = variant_label(text)
  local reading = table.concat(reference, ' - ')
  local comment = mode == 'word' and reading
    or ('_音 ' .. table.concat(on_reference, ' - ') .. ' | _訓 ' .. table.concat(kun_reference, ' - '))
  return {comment=comment,
    reading=reading, commit=table.concat(commit, ' '), variant=variant}
end

-- Final UI string only. Character-position metadata and group markers are
-- deliberately separate from candidate.text and all exported commit values.
function M.comment(text, state, from_chinese)
  local comment = variant_metadata(text)
  if state.held and utf8.len(text) > 1 and from_chinese and not M.known_word(text) then
    comment = comment .. ' | _中 '
  end
  if state.held and state.closed then
    comment = comment .. ' | ' .. M.describe(text, state.mode).comment
  end
  return comment
end

local function selected_prefix(ctx, finish)
  local pieces, words = {}, {}
  for _, seg in ipairs(ctx.composition:toSegmentation():get_segments()) do
    if seg._end > finish then break end
    if seg.status ~= 'kSelected' and seg.status ~= 'kConfirmed' then break end
    local candidate = seg:get_selected_candidate()
    pieces[#pieces + 1] = candidate and candidate.text or ctx.input:sub(seg.start + 1, seg._end)
    if candidate then
      local genuine = candidate:get_genuine()
      words[#words + 1] = genuine.type == bracket_kind
        and genuine:to_phrase().entry.text or candidate.text
    end
  end
  return table.concat(pieces), words
end

-- qQ/xX share the same context-owned spelling stops and commit snapshot.
M.remember_navigation = remember_navigation
M.navigate_query = navigate_query
M.selected_prefix = selected_prefix
M.variant_metadata = variant_metadata
function M.navigation(ctx)
  return navigation_owners[ctx:get_property('jp_v_navigation_owner')]
end

function M.confirm_bracket(ctx, candidate, text, character, owner)
  if candidate.type == bracket_kind and candidate.text == text then
    ctx:confirm_current_selection()
    return
  end
  local phrase = Phrase(owner.mem, bracket_kind, candidate.start, candidate._end,
                        memory.entry(owner, character))
  local picked = ShadowCandidate(phrase:toCandidate(), bracket_kind, text, '')
  select_hanzi.confirm(ctx, picked)
end

-- All values are snapshotted before commit/clear, including actual shown text.
function M.submit(ctx, candidate, text, engine, learned_text)
  if not kind(candidate) then return false end
  local state = M.parse(ctx, candidate.start)
  if not state then return false end
  local before, prior_words = selected_prefix(ctx, candidate.start)
  local tail = state.raw:sub(math.min(candidate._end, state.body_end) + 1, state.body_end)
  if tail ~= '' and state.held then tail = 'vV' .. tail .. state.marker end
  engine:commit_text(before .. text)
  local owner = memory.acquire(engine)
  -- Direct annotated/character commits bypass Context's native Memory hook.
  -- Learn selected prefix pieces and the actual target exactly once here.
  for _, prior in ipairs(prior_words) do memory.learn(owner, prior) end
  if learned_text ~= false then memory.learn(owner, learned_text or candidate.text) end
  memory.release(owner)
  ctx:clear()
  if tail ~= '' then ctx:push_input(tail) end
  return true
end

M.segmentor = {}
function M.segmentor.func(segmentation, env)
  local ctx = env.engine.context
  local start = segmentation:get_current_start_position()
  if ctx:get_option('ascii_mode') or not M.parse(ctx, start) then return true end
  -- A caret move edits the same query, rather than truncating its right side.
  segmentation.input = ctx.input
  if start >= #ctx.input then return true end
  local seg = Segment(start, #ctx.input)
  seg.tags = Set({'jp_v_lookup', 'raw_preedit'})
  segmentation:add_segment(seg)
  return false
end

M.translator = {}
function M.translator.init(env)
  shared_init(env)
  -- Japanese data, with the same matching/order/boundary implementation as PC.
  env.japanese_module = require('cn_translator')
  env.japanese = {engine=env.engine}
  env.japanese_module.init_chinese(env.japanese, Schema('jp_v_lookup'))
end
function M.translator.fini(env)
  if env.japanese then env.japanese_module.fini_chinese(env.japanese) end
  if env.chinese then env.chinese_module.fini_chinese(env.chinese) end
  env.kana = nil
  env.japanese, env.japanese_module, env.chinese, env.chinese_module = nil, nil, nil, nil
  shared_fini(env)
end

-- Prototype admission policy, deliberately isolated from stream mechanics.
-- It can be relaxed after the separate word-scope decision without changing
-- the lookup engine or candidate spans.
local function admitted_chinese_text(text)
  for _, cp in utf8.codes(text) do
    if not han(cp) or not data().get_character(utf8.char(cp)) then return false end
  end
  return text ~= ''
end

local function chinese_translation(query, query_seg, env)
  if not env.chinese then
    env.chinese_module = require('cn_translator')
    env.chinese = {engine=env.engine}
    env.chinese_module.init_chinese(env.chinese, Schema('jp_v_pc_lookup'))
  end
  return Translation(env.chinese_module.query_chinese, query, query_seg, env.chinese)
end

local function lookup_stream(translation, source, state, start, env)
  local stream = {source=source}
  if translation then stream.next, stream.state = translation:iter() end
  function stream:advance()
    self.head = nil
    while self.next do
      local candidate = self.next(self.state)
      if not candidate then break end
      local admitted = candidate._end > start
      if source == 'chinese' then
        admitted = admitted and admitted_chinese_text(candidate.text)
      elseif state.held and utf8.len(candidate.text) > 1 then
        -- A Japanese native sentence can be composed from individual Kanji.
        -- Without an actual whole-word record, leave this spelling to the
        -- Chinese stream so its source marker cannot disappear by deduping.
        admitted = admitted and M.known_word(candidate.text)
      end
      if admitted then
        self.head, self.learned, self.match_kind = candidate, false, nil
        local phrase = candidate:get_genuine():to_phrase()
        if candidate.type == 'cn_full' then self.match_kind = 0
        elseif phrase then
          local decoder_env = source == 'chinese' and env.chinese or env.japanese
          self.match_kind = require('cn_match').classify(
            state.raw:sub(candidate.start + 1, candidate._end),
            decoder_env.decoder:decode(phrase.code), require('cn_forms'),
            state.raw:sub(start + 1, state.body_end), decoder_env.extra_forms)
        end
        if source == 'chinese' then
          -- DictEntry keeps the existing learning identity even when the core
          -- relabels a full match as cn_full. No display comment is metadata.
          if phrase and phrase.entry.commit_count > 0 then
            self.learned = self.match_kind ~= nil
          end
        end
        memory.observe_prior(env.jp_owner, candidate.text, candidate, source)
        self.match_kind = self.match_kind or (candidate.type == 'cn_full' and 0 or 1)
        self.score = memory.score(env.jp_owner, candidate.text)
        break
      end
    end
  end
  stream:advance()
  return stream
end

local function learned_stream(query, start, state, env, q)
  local items = {}
  local entries = memory.learned(env.jp_owner)
  if #entries > 0 then learned_match = learned_match or require('jp_learning_match') end
  local ordinary = query:match("^([a-z]+)[' ]*$")
  local single_full = not q and ordinary and env.japanese.normal_spellings[ordinary] == 0
  for _, entry in ipairs(entries) do
    local matches = q and learned_match.q(entry.text, query, memory.readings(env.jp_owner, entry.text))
      or learned_match.pinyin(entry.text, query, env.japanese.extra_forms)
    local ending, best
    for stop, matched in pairs(matches) do
      if not (single_full and utf8.len(entry.text) == 1 and matched.kind == 1) then
        -- Preserve an available normal boundary instead of consuming a letter
        -- from the remaining word through an extra-letter interpretation.
        if not best or (best.kind == 2 and matched.kind < 2)
            or ((best.kind == 2) == (matched.kind == 2) and stop > ending)
            or (stop == ending and matched.kind < best.kind) then
          ending, best = stop, matched
        end
      end
    end
    if best then
      local original = Candidate(best.kind == 0 and 'cn_full' or 'jp_learned',
        start, start + ending, entry.text, '')
      original.preedit = query:sub(1, ending)
      local vertices = {}
      for _, vertex in ipairs(best.vertices) do vertices[#vertices + 1] = start + vertex end
      items[#items + 1] = {head=original, match_kind=best.kind, vertices=vertices,
        score=memory.score(env.jp_owner, entry.text), source='learned'}
    end
  end
  table.sort(items, function(a, b)
    if a.head._end ~= b.head._end then return a.head._end > b.head._end end
    if a.match_kind == 0 and b.match_kind == 2 then return true end
    if a.match_kind == 2 and b.match_kind == 0 then return false end
    if a.score ~= b.score then return a.score > b.score end
    return a.head.text < b.head.text
  end)
  local stream, index = {source='learned'}, 0
  function stream:advance()
    index = index + 1
    local item = items[index]
    self.head = item and item.head
    self.score = item and item.score
    self.match_kind = item and item.match_kind
    self.vertices = item and item.vertices
  end
  stream:advance()
  return stream
end

local function prefer(a, b)
  if not b or not b.head then return true end
  if a.head._end ~= b.head._end then return a.head._end > b.head._end end
  if a.match_kind == 0 and b.match_kind == 2 then return true end
  if a.match_kind == 2 and b.match_kind == 0 then return false end
  return a.score > b.score
end

local function all_kana(text)
  for _, cp in utf8.codes(text) do
    if not ((cp >= 0x3041 and cp <= 0x309f) or (cp >= 0x30a1 and cp <= 0x30ff) or
        (cp >= 0x31f0 and cp <= 0x31ff) or (cp >= 0x1b000 and cp <= 0x1b16f)) then return false end
  end
  return text ~= ''
end

local function native_kana(query, start, ending, env)
  if not env.kana then
    env.kana = Component.Translator(env.engine, env.engine.schema, '', 'script_translator@jp_v_kana')
  end
  if not env.kana then return end
  local seg = Segment(start, ending)
  seg.tags = Set({'abc'})
  local translation = env.kana:query(query, seg)
  if not translation then return end
  for candidate in translation:iter() do
    if candidate._end ~= ending then break end
    if candidate:get_genuine().type ~= 'completion' and all_kana(candidate.text) then return candidate end
  end
end

-- One exact Pinyin head followed by native romaji, without another dictionary
-- or an entry containing a synthetic Han-and-kana surface.
local function kana_tail(query, start, ending, env)
  if not query:match("^[a-z][a-z' ]*[a-z]$") or #query < 3 then return end
  local pinyin = env.japanese
  local matcher, forms = require('cn_match'), require('cn_forms')
  for head_length = math.min(#query - 1, pinyin.normal_max_length), 1, -1 do
    local head = query:sub(1, head_length)
    if pinyin.normal_spellings[head] == 0 then
      local tail_start = head_length + 1
      while query:sub(tail_start, tail_start):match("[' ]") do tail_start = tail_start + 1 end
      local kana = native_kana(query:sub(tail_start), start + tail_start - 1, ending, env)
      if kana then
        local head_end = start + head_length
        local head_seg = Segment(start, head_end)
        head_seg.tags = Set({'abc'})
        local translation = pinyin.native:query(head:upper(), head_seg)
        if translation then
          local candidates, seen = {}, {}
          for candidate in translation:iter() do
            if candidate._end ~= head_end then break end
            local phrase = candidate:get_genuine():to_phrase()
            if phrase and utf8.len(candidate.text) == 1 and han(utf8.codepoint(candidate.text)) and
                phrase.type ~= 'sentence' and phrase.type ~= 'completion' and
                matcher.classify(head, pinyin.decoder:decode(phrase.code), forms, head, pinyin.extra_forms) == 0 then
              local canonical = family.resolve(candidate.text)
              if not seen[canonical] then
                seen[canonical] = true
                candidates[#candidates+1] = candidate
                if #candidates == 3 then break end
              end
            end
          end
          if #candidates > 0 then return candidates, kana end
        end
      end
    end
  end
end

function M.translator.func(_, seg, env)
  local ctx = env.engine.context
  if ctx:get_option('ascii_mode') then return end
  local state = M.parse(ctx, seg.start)
  if not state or not state.body:match("^[a-z' ]+$") then return end
  memory.begin_query(env.jp_owner)
  local start = math.max(seg.start, state.body_start)
  if start >= state.body_end then return end
  local query = state.raw:sub(start + 1, state.body_end)
  local query_seg = Segment(start, state.body_end)
  query_seg.tags = Set({'abc'})
  local native = Translation(env.japanese_module.query_chinese,
      query, query_seg, env.japanese)
  local jp = lookup_stream(native, 'japanese', state, start, env)
  local chinese = state.held and lookup_stream(chinese_translation(query, query_seg, env), 'chinese', state, start, env)
  local learned = learned_stream(query, start, state, env, false)
  local seen, ordinal = {}, 0
  local pending_kana = not state.held
  while jp.head or (chinese and chinese.head) or learned.head do
    local stream = jp
    if chinese and chinese.head and prefer(chinese, stream) then stream = chinese end
    if learned.head and prefer(learned, stream) then stream = learned end
    local candidate = stream.head
    local ending = candidate._end
    if pending_kana then
      pending_kana = false
      -- A complete dictionary word keeps the existing lookup unchanged.
      -- A generated sentence is not evidence of an exact whole word.
      if ending < state.body_end or stream.match_kind ~= 0 or candidate:get_genuine():to_sentence() then
        local heads, kana = kana_tail(query, start, state.body_end, env)
        for _, head in ipairs(heads or {}) do
          local text = head.text .. kana.text
          local canonical = Phrase(env.jp_owner.mem, kana_tail_kind, seg.start, state.body_end,
                                   memory.entry(env.jp_owner, head.text))
          local shown = ShadowCandidate(canonical:toCandidate(), kana_tail_kind, text, variant_metadata(head.text))
          shown.start, shown._end, shown.preedit = seg.start, state.body_end, state.raw
          ordinal = ordinal + 1
          shown.quality = 1000000 - ordinal
          local vertices = head:spans().vertices
          for _, vertex in ipairs(kana:spans().vertices) do
            if vertex > head._end then vertices[#vertices+1] = vertex end
          end
          remember_navigation(ctx, shown, head, state, vertices)
          yield(shown)
        end
      end
    end
    local identity = family.resolve(candidate.text) .. '\t' .. ending
    if ending > start and not seen[identity] then
      seen[identity] = true
      -- Ordinary v and unfinished vV remain plain lookup interfaces. Only a
      -- currently closed vV...v/V draft requests visible reading information.
      local from_chinese = stream.source == 'chinese'
      if ending == state.body_end then ending = #state.raw end
      for _, text in ipairs(family.members(candidate.text)) do
        ordinal = ordinal + 1
        local comment = M.comment(text, state, from_chinese)
        local wrapped = memory.wrap(env.jp_owner, candidate, text, comment,
          'jp_v_' .. state.mode .. (from_chinese and '_cn' or ''))
        wrapped.start, wrapped._end = seg.start, ending
        wrapped.preedit = state.raw:sub(seg.start + 1, ending)
        wrapped.quality = 1000000 - ordinal
        remember_navigation(ctx, wrapped, candidate, state, stream.vertices)
        yield(wrapped)
      end
    end
    stream:advance()
  end
end

M.filter = {}
M.filter.init = shared_init
M.filter.fini = shared_fini
function M.filter.func(input, env)
  local ctx = env.engine.context
  -- q/qQ now have a shared sourced lookup/filter; do not learn or wrap twice.
  local query_state = require('jp_query').parse(ctx)
  if query_state and query_state.held then
    for candidate in input:iter() do yield(candidate) end
    return
  end
  local active = M.parse(ctx) ~= nil
  if not active and query_state and query_state.body ~= '' then
    memory.begin_query(env.jp_owner)
    local state = {raw=ctx.input, body_start=0, body_end=#ctx.input}
    local start = ctx.composition:empty() and 0 or ctx.composition:back().start
    local learned = learned_stream(ctx.input:sub(start + 1), start, state, env, true)
    local next_candidate, iterator_state = input:iter()
    local native = {source='legacy_q'}
    function native:advance()
      self.head = next_candidate(iterator_state)
      if self.head then
        if self.head.type ~= 'jp_q_form' then
          memory.observe_prior(env.jp_owner, self.head.text, self.head, 'legacy_q')
        end
        self.score = memory.score(env.jp_owner, self.head.text)
        self.match_kind = 0
      end
    end
    native:advance()
    local seen = {}
    while native.head or learned.head do
      local stream = learned.head and prefer(learned, native) and learned or native
      local candidate = stream.head
      local identity = family.resolve(candidate.text) .. '\t' .. candidate._end
      if not seen[identity] then
        seen[identity] = true
        if family.is_han(candidate.text) or require('jp_query').admitted(candidate.text) then
          local query = ctx.input:sub(candidate.start + 1, candidate._end)
          local members = require('jp_query').members(candidate.text, query)
          -- Preserve a legitimate native completion even when the full-code
          -- learned-word matcher does not handle that incomplete spelling.
          if #members == 0 then members = {candidate.text} end
          for _, text in ipairs(members) do
            local comment = variant_metadata(text) .. candidate.comment
            local wrapped = candidate.type == 'jp_q_form' and text == candidate.text and candidate
              or memory.wrap(env.jp_owner, candidate, text, comment, 'jp_q')
            remember_navigation(ctx, wrapped, candidate, state, stream.vertices)
            yield(wrapped)
          end
        else yield(candidate) end
      end
      stream:advance()
    end
    return
  end
  for candidate in input:iter() do
    if kind(candidate) then active = true; yield(candidate)
    elseif not active then yield(candidate) end
  end
end

local mode_hints = {
  vV='漢字·拼音モード',
  qQ='漢字·ローマ字モード',
  xX='小書き仮名モード',
}
local function update_mode_hint(ctx)
  local text = not ctx:get_option('ascii_mode') and mode_hints[ctx.input] or ''
  if ctx:get_property('auxiliary_text') ~= text then
    ctx:set_property('auxiliary_text', text)
  end
end

local nav = {[0x2c]='Up', [0x2e]='Down', [0x2d]='Page_Up', [0x3d]='Page_Down'}
local function submit_bracket(ctx, state, candidate, text, character, env)
  if state.held and candidate._end < state.body_end then
    M.confirm_bracket(ctx, candidate, text, character, env.jp_owner)
  else
    M.submit(ctx, candidate, text, env.engine, character)
  end
end

M.processor = {}
function M.processor.init(env)
  shared_init(env)
  navigation_serial = navigation_serial + 1
  env.navigation_id = tostring(navigation_serial)
  env.navigation = {raw='', candidates={}}
  navigation_owners[env.navigation_id] = env.navigation
  local ctx = env.engine.context
  ctx:set_property('jp_v_navigation_owner', env.navigation_id)
  env.navigation_select = ctx.select_notifier:connect(function() env.navigation.moving = nil end)
  env.navigation_update = ctx.update_notifier:connect(function()
    if env.navigation.raw ~= ctx.input then
      env.navigation.raw, env.navigation.candidates, env.navigation.moving = ctx.input, {}, nil
    end
    update_mode_hint(ctx)
  end)
  env.mode_hint_option = ctx.option_update_notifier:connect(function(_, name)
    if name == 'ascii_mode' then update_mode_hint(ctx) end
  end)
  update_mode_hint(ctx)
  env.selector = assert(Component.Processor(env.engine, '', 'selector'))
end
function M.processor.fini(env)
  env.mode_hint_option:disconnect()
  env.engine.context:set_property('auxiliary_text', '')
  env.navigation_select:disconnect()
  env.navigation_update:disconnect()
  navigation_owners[env.navigation_id] = nil
  env.navigation, env.selector = nil, nil
  shared_fini(env)
end
function M.processor.func(key, env)
  local ctx = env.engine.context
  if ctx:get_option('ascii_mode') or key:release() or key:alt()
      or key:super() then return 2 end
  local state = M.parse(ctx)
  if not state then
    if ctx.input:match("^q[a-z' ]+$") and require('jp_query').parse(ctx)
        and navigate_query(key, ctx, env.navigation) then return 1 end
    return 2
  end
  if navigate_query(key, ctx, env.navigation) then return 1 end
  local code = key.keycode
  local group, take_first
  if state.mode == 'char' then
    if key:ctrl() and not key:shift() and (code == 0x5b or code == 0x5d) then
      group, take_first = 'kun', code == 0x5b
    elseif key:shift() and not key:ctrl() and (code == 0x7b or code == 0x7d) then
      group, take_first = 'on', code == 0x7b
    end
  end
  if group then
    local candidate = ctx:get_selected_candidate()
    if not kind(candidate) then return 1 end
    local first, last
    for _, cp in utf8.codes(candidate.text) do
      if han(cp) then first = first or cp; last = cp end
    end
    if first then
      local character = utf8.char(take_first and first or last)
      submit_bracket(ctx, state, candidate, M.describe(character, 'char', group).commit,
                     character, env)
    end
    return 1
  end
  if key:ctrl() then return 2 end
  if not key:shift() and nav[code] then
    if ctx:has_menu() then env.selector:process_key_event(KeyEvent(nav[code])) end
    return 1
  end
  if key:shift() then return 2 end
  if state.held and (code == 0xff0d or code == 0xff8d) then
    local start = state.body_start
    if not ctx.composition:empty() then start = math.max(start, ctx.composition:back().start) end
    local text = selected_prefix(ctx, start) .. state.raw:sub(start + 1, state.body_end)
    if text ~= '' then env.engine:commit_text(text) end
    ctx:clear()
    return 1
  end
  if state.held and (code == 0x5b or code == 0x5d) then
    local candidate = ctx:get_selected_candidate()
    if not kind(candidate) then return 1 end
    local first, last
    for _, cp in utf8.codes(candidate.text) do
      if han(cp) then first = first or cp; last = cp end
    end
    if first then
      local character = utf8.char(code == 0x5b and first or last)
      submit_bracket(ctx, state, candidate, character, character, env)
    end
    return 1
  end
  -- vV owns its control alphabet. A final v/V is an editable marker, never
  -- an automatic commit trigger. Native speller handles cursor/backspace.
  if state.held and code >= 0x41 and code <= 0x7a then
    local character = string.char(code)
    if character:match('^[a-zV]$') then ctx:push_input(character); return 1 end
  end
  return 2
end

return M
