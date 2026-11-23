-- Japanese symbol names are exact whole-draft queries. They never become
-- syllables inside longer romaji words or inside q/v lookup bodies.
local M = {}
local entries = {
  kuten = { '。' },
  touten = { '、' },
  kagikakko = { '「', '」' },
  ten = { '。', '、' },
  kakko = { '「', '」', '『', '』', '（', '）' },
  inyoufu = { '“', '”', '‘', '’' },
  dasshu = { '―', '――' },
}

function M.func(input, seg, env)
  local ctx = env.engine.context
  if ctx:get_option('ascii_mode') or seg.start ~= 0
      or seg._end ~= #ctx.input or input ~= ctx.input then return end
  local values = entries[input]
  if not values then return end
  for i, text in ipairs(values) do
    local candidate = Candidate('jp_named_symbol', seg.start, seg._end, text, '')
    candidate.quality = 10 - i * 0.01
    yield(candidate)
  end
end

return M
