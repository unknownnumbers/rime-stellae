-- SPDX-License-Identifier: GPL-3.0-only
-- Isolated processor checks. All inputs and contexts are synthetic.
local checked = 0
local limit_calls = 0
local allowed = true
package.loaded.draft_limit = {
  allow_context = function(_, _, character)
    assert(character == '"')
    limit_calls = limit_calls + 1
    return allowed
  end,
}
local processor_path = assert(..., 'An explicit synthetic processor path is required')
local processor = assert(loadfile(processor_path))()

local function check(name, specification)
  local spec = specification or {}
  local input = spec.input or 'nihao'
  local caret = spec.caret or #input
  local confirmed = spec.confirmed or 0
  local tags = spec.tags or {abc=true}
  local composition = {}
  function composition:empty() return spec.empty or false end
  function composition:back()
    return {has_tag=function(_, tag) return tags[tag] or false end}
  end
  function composition:toSegmentation()
    return {get_confirmed_position=function() return confirmed end}
  end
  local pushes, deletes, clears = 0, 0, 0
  local ctx = {input=input, caret_pos=caret, composition=composition}
  function ctx:get_option(option) return spec[option] or false end
  function ctx:push_input(character)
    self.input = self.input:sub(1, self.caret_pos) .. character
      .. self.input:sub(self.caret_pos + 1)
    self.caret_pos = self.caret_pos + #character
    pushes = pushes + 1
  end
  function ctx:delete_input(length)
    assert(length == 1, name .. ': delete length')
    assert(clears == 1, name .. ': cached menu cleared before delete')
    self.input = self.input:sub(1, self.caret_pos) .. self.input:sub(self.caret_pos + length + 1)
    deletes = deletes + 1
  end
  function ctx:clear_non_confirmed_composition() clears = clears + 1 end
  local key = {keycode=spec.keycode or 0x22}
  for _, modifier in ipairs({'release', 'ctrl', 'alt', 'super', 'shift'}) do
    local flag = modifier
    key[flag] = function() return spec[flag] or false end
  end
  allowed = spec.allowed ~= false
  local prior_calls = limit_calls
  local result = processor.func(key, {engine={context=ctx,
    schema={schema_id=spec.schema_id or 'pc_research'}}})
  local expected = spec.result or 1
  assert(result == expected, name .. ': result')
  local deleting = key.keycode == 0xffff and expected == 1
  local inserts = not deleting and expected == 1 and allowed
  local expected_input = deleting and input:sub(1, caret) .. input:sub(caret + 2)
    or (inserts and input:sub(1, caret) .. '"' .. input:sub(caret + 1) or input)
  assert(ctx.input == expected_input, name .. ': input')
  assert(pushes == (inserts and 1 or 0), name .. ': pushes')
  assert(deletes == (deleting and 1 or 0), name .. ': deletes')
  assert(clears == (deleting and 1 or 0), name .. ': menu invalidation')
  assert(limit_calls-prior_calls == (expected == 1 and not deleting and 1 or 0), name .. ': limit')
  checked = checked + 1
end

check('shifted physical quote', {shift=true})
check('unknown spelling stays editable', {input='zzzz'})
check('caret insertion preserves remainder', {caret=2})
check('existing markers remain raw', {input='ni"hao\'ma'})
check('confirmed prefix is not reinterpreted', {input='cC12ni', confirmed=4})
check('limit refusal only consumes quote', {allowed=false})
check('empty draft', {input='', result=2})
check('caret at start', {caret=0, result=2})
check('caret at confirmed boundary', {confirmed=5, result=2})
check('no block after apostrophe', {input="ni'", result=2})
check('no block after quote', {input='ni"', result=2})
check('no block after space', {input='ni ', result=2})
check('uppercase tool input', {input='cC12', result=2})
check('reverse lookup input', {input='uUabc', result=2})
check('ASCII mode', {ascii_mode=true, result=2})
check('English mode', {research_english=true, result=2})
check('Japanese schema', {schema_id='jp_sela', result=2})
check('empty composition', {empty=true, result=2})
for _, tag in ipairs({'reverse_lookup', 'u_lookup', 'tool_calculator', 'tool_unicode'}) do
  local tags = {abc=true}
  tags[tag] = true
  check('excluded tag ' .. tag, {tags=tags, result=2})
end
for _, modifier in ipairs({'release', 'ctrl', 'alt', 'super'}) do
  check('excluded modifier ' .. modifier, {[modifier]=true, result=2})
end
check('Return is native', {keycode=0xff0d, result=2})
check('Tab is navigation only', {keycode=0xff09, result=2})
check('forward delete invalid closing quote refreshes cached menu',
  {keycode=0xffff, input='xioa"', caret=4})
check('forward delete apostrophe changes lock scope',
  {keycode=0xffff, input='xi\'ao"', caret=2})
check('forward delete first pending letter needs no left block',
  {keycode=0xffff, input='xiao"', caret=0})
check('forward delete at confirmed boundary',
  {keycode=0xffff, input='nixiao"', confirmed=2, caret=2})
check('forward delete before confirmed boundary stays native',
  {keycode=0xffff, input='nixiao"', confirmed=2, caret=1, result=2})
check('forward delete at end stays native', {keycode=0xffff, input='xiao"', result=2})
check('forward delete unmarked draft stays native',
  {keycode=0xffff, input='xiao', caret=2, result=2})
check('forward delete marker only in confirmed prefix stays native',
  {keycode=0xffff, input='ni"hao', confirmed=3, caret=4, result=2})
check('Shift Delete remains candidate reset',
  {keycode=0xffff, input='xiao"', caret=2, shift=true, result=2})
check('Ctrl Delete remains native',
  {keycode=0xffff, input='xiao"', caret=2, ctrl=true, result=2})
check('forward Delete in English remains native',
  {keycode=0xffff, input='xiao"', caret=2, research_english=true, result=2})
check('forward Delete in Japanese remains native',
  {keycode=0xffff, input='xiao"', caret=2, schema_id='jp_sela', result=2})
check('forward Delete in tools remains native',
  {keycode=0xffff, input='xiao"', caret=2, tags={abc=true, tool_calculator=true}, result=2})

function Segment(start, finish) return {start=start, _end=finish} end
function Set(tags)
  local result = {}
  for _, tag in ipairs(tags) do result[tag] = true end
  return result
end

local function check_segment(name, spec)
  local raw = spec.input or 'xiao"ma'
  local original = raw
  local start = spec.start or 0
  local segments = {}
  local segmentation = {input=raw}
  function segmentation:get_current_start_position() return start end
  function segmentation:add_segment(segment) segments[#segments + 1] = segment end
  local ctx = {input=spec.context_input or raw}
  function ctx:get_option(option) return spec[option] or false end
  local result = processor.segmentor.func(segmentation, {engine={context=ctx,
    schema={schema_id=spec.schema_id or 'pc_research'}}})
  local claim = spec.word ~= nil
  assert(result == not claim, name .. ': segmentor result')
  assert(segmentation.input == original, name .. ': segmentation input unchanged')
  assert(ctx.input == (spec.context_input or raw), name .. ': context input unchanged')
  assert(#segments == (claim and 1 or 0), name .. ': segment count')
  if claim then
    local segment = segments[1]
    assert(segment.start == start and segment._end == start + #spec.word,
      name .. ': segment offsets')
    assert(segment.tags.abc, name .. ': abc tag')
  end
  checked = checked + 1
end

check_segment('marked Chinese prefix', {word='xiao"ma'})
check_segment('unmarked Chinese unchanged', {input="ni'hao"})
check_segment('supplied input ends at caret', {input='xiao', context_input='xiao"ma'})
check_segment('supplied marked input ends at caret',
  {input='xiao"', context_input='xiao"ma', word='xiao"'})
check_segment('offset preserves prior segment', {input='XXxiao"ma', start=2, word='xiao"ma'})
check_segment('stops at unrelated punctuation', {input='xiao"ma!', word='xiao"ma'})
check_segment('apostrophe leading boundary', {input="'xiao\"ma", word="'xiao\"ma"})
check_segment('initial literal quote unchanged', {input='"xiao'})
check_segment('quote after empty block unchanged', {input="ni'\""})
check_segment('calculator unchanged', {input='cC1+2"'})
check_segment('reverse lookup unchanged', {input='uUabc"'})
check_segment('Unicode tool unchanged', {input='U4E2D"'})
check_segment('English segmentation unchanged', {research_english=true})
check_segment('ASCII segmentation unchanged', {ascii_mode=true})
check_segment('Japanese segmentation unchanged', {schema_id='jp_sela'})
print('cn_exact_processor: ' .. checked .. ' synthetic checks passed')
return checked
