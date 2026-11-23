local M = {}

function M.func(segmentation, env)
  local ctx = env.engine.context
  if ctx:get_option('research_english') or ctx:get_option('ascii_mode') then return true end
  local start = segmentation:get_current_start_position()
  if start ~= 0 then return true end
  local input = segmentation.input:sub(start + 1)
  -- Calculation covers the unconfirmed formula even while its caret is inside
  -- the cC prefix. Other input tools retain their own segmentation rules.
  local kind = ctx.input:sub(1, 2) == 'cC' and 'calculator'
      or (input:match('^U%x*$') and 'unicode')
      or (input:match("^uU[a-z]*U?'?$") and 'lookup')
  if not kind then return true end
  if kind == 'calculator' then segmentation.input = ctx.input end
  local seg = Segment(start, #segmentation.input)
  seg.tags = kind == 'calculator' and Set({'tool_calculator', 'raw_preedit'})
      or (kind == 'lookup' and Set({'abc', 'reverse_lookup'}) or Set({'tool_unicode'}))
  segmentation:add_segment(seg)
  return false
end

return M
