local calculator = require('tool_calculator')
local unicode = require('tool_unicode')
local M = {}
local U_HELP = '拼音拆字/五筆畫-(橫,h) (豎,s) (撇, p) (捺,n) (折,z)'

local function show_hint(ctx, hint)
  ctx:set_property('auxiliary_text', hint or '')
  ctx.composition:back().prompt = ''
end

function M.init(env)
  env.cache, env.draft = {}, ''
  env.engine.context:set_property('auxiliary_text', '')
  env.update = env.engine.context.update_notifier:connect(function(ctx)
    if ctx.input ~= env.draft then env.cache = {}; env.draft = ctx.input end
    if ctx.composition:empty() or ctx:get_option('research_english')
        or ctx:get_option('ascii_mode') then
      ctx:set_property('auxiliary_text', '')
      return
    end
    local seg = ctx.composition:back()
    if seg:has_tag('reverse_lookup') and ctx.input:sub(seg.start + 1, seg.start + 2) == 'uU' then
      show_hint(ctx, ctx.input:sub(seg.start + 1) == 'uU' and U_HELP or nil)
    elseif not seg:has_tag('tool_calculator') and not seg:has_tag('tool_unicode') then
      ctx:set_property('auxiliary_text', '')
    end
  end)
end

function M.fini(env)
  env.update:disconnect()
  env.engine.context:set_property('auxiliary_text', '')
end

function M.func(input, seg, env)
  local ctx = env.engine.context
  if ctx:get_option('research_english') or ctx:get_option('ascii_mode') then return end
  local kind, rows, hint
  if seg:has_tag('tool_calculator') then
    if ctx.input ~= env.draft then env.cache = {}; env.draft = ctx.input end
    local expression = input:sub(3)
    local result = env.cache[expression]
    if not result then result = calculator.evaluate(expression); env.cache[expression] = result end
    kind, rows, hint = 'tool_calc', {}, result.hint
    if result.text then
      rows = {{text=expression .. '=' .. result.text, comment=''}, {text=result.text, comment=''}}
    end
    show_hint(ctx, expression == '' and 'Calculator' or hint)
  elseif seg:has_tag('tool_unicode') then
    kind = 'tool_unicode'
    rows, hint = unicode.query(input)
    show_hint(ctx, input == 'U' and 'Unicode Input' or (#input >= 3 and hint or nil))
  else return end
  for index, row in ipairs(rows) do
    local candidate = Candidate(kind, seg.start, seg._end, row.text, row.comment)
    candidate.preedit = input
    candidate.quality = 1000000 - index
    yield(candidate)
  end
end

return M
