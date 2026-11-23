-- Adapted to the local segment model from Ice's select_character.lua idea.
-- Upstream: BlindingDark/rime-lua-select-character; iDvel/rime-ice (GPL-3.0).
-- Unlike the original text substitution, use segment offsets to preserve raw tails.
local M = {}

function M.confirm(ctx, picked)
  local seg = ctx.composition:back()
  local original_menu = seg.menu
  local menu = Menu()
  -- Keep the other choices available if the user reopens this segment.
  menu:add_translation(Translation(function()
    yield(picked)
    local index = 0
    local alternative = original_menu:get_candidate_at(index)
    while alternative do
      yield(alternative)
      index = index + 1
      alternative = original_menu:get_candidate_at(index)
    end
  end))
  seg.menu = menu
  seg.selected_index = 0
  ctx:confirm_current_selection()
end

local function han(cp)
  return cp == 0x3007 or (cp >= 0x3400 and cp <= 0x4dbf)
      or (cp >= 0x4e00 and cp <= 0x9fff) or (cp >= 0xf900 and cp <= 0xfaff)
      or (cp >= 0x20000 and cp <= 0x2fa1f) or (cp >= 0x30000 and cp <= 0x3347f)
end

local function learned_character(ctx, candidate, text, index)
  local original = candidate:get_genuine():to_phrase()
  local decoder = require('cn_preedit_spacing').decoder(ctx)
  if not original or not decoder then return end
  local mixed = original.type == 'research_mixed'
  local syllables
  if mixed then
    for _, item in ipairs(require('mixed_data')) do
      if item.text == original.text then syllables = item.syllables; break end
    end
  elseif original.lang_name == decoder.lang_name then
    syllables = decoder:decode(original.code)
  end
  if not syllables or utf8.len(original.text) ~= utf8.len(candidate.text) then return end
  local characters = {}
  local position, selected = 0, nil
  for _, cp in utf8.codes(original.text) do
    position = position + 1
    if han(cp) then
      characters[#characters + 1] = utf8.char(cp)
      if position == index then selected = #characters end
    elseif not mixed then return end
  end
  if not selected or #syllables ~= #characters then return end
  local syllable = syllables[selected]
  local forms = require('cn_forms')[syllable]
  if not forms then return end
  local spelling = syllable
  for raw, kind in pairs(forms.values) do
    if kind == 0 then spelling = raw; break end
  end
  for entry in decoder.dict:lookup_words(spelling, false, 0):iter() do
    if entry.text == characters[selected] then
      local code = decoder:decode(entry.code)
      if #code == 1 and code[1] == syllable then
        local phrase = Phrase(decoder, 'bracket_character', candidate.start, candidate._end, entry)
        return ShadowCandidate(phrase:toCandidate(), 'bracket_character', text, '')
      end
    end
  end
end

function M.func(key, env)
  local ctx = env.engine.context
  if ctx:get_option('research_english') or ctx:get_option('ascii_mode')
      or key:release() or key:ctrl() or key:alt() or key:super()
      or (key.keycode ~= 0x5b and key.keycode ~= 0x5d) then return 2 end
  local candidate = ctx:get_selected_candidate()
  if not candidate then return 2 end
  local kind = candidate:get_genuine().type
  if kind:match('^u_') or kind:match('^tool_') then return 2 end
  local first, last, first_index, last_index, index = nil, nil, nil, nil, 0
  for _, cp in utf8.codes(candidate.text) do
    index = index + 1
    if han(cp) then
      if not first then first, first_index = cp, index end
      last, last_index = cp, index
    end
  end
  if not first then return 2 end
  local take_first = key.keycode == 0x5b
  local text = utf8.char(take_first and first or last)
  local picked = learned_character(ctx, candidate, text, take_first and first_index or last_index)
  if picked then
    M.confirm(ctx, picked)
    if candidate._end == #ctx.input and ctx:is_composing() then ctx:commit() end
    return 1
  end
  if candidate._end < #ctx.input then
    if kind == 'bracket_character' then
      ctx:confirm_current_selection()
    else
      M.confirm(ctx, Candidate('bracket_character', candidate.start, candidate._end, text, ''))
    end
    return 1
  end
  local before = {}
  for _, seg in ipairs(ctx.composition:toSegmentation():get_segments()) do
    if seg._end > candidate.start then break end
    local prior = seg:get_selected_candidate()
    before[#before + 1] = prior and prior.text or ctx.input:sub(seg.start + 1, seg._end)
  end
  env.engine:commit_text(table.concat(before) .. text)
  ctx:clear()
  return 1
end

return M
