-- Interpret only the unconfirmed English remainder; selected segments survive.
local M = {}

function M.func(segmentation, env)
  local ctx = env.engine.context
  if ctx:get_option('ascii_mode') then return true end
  local english = ctx:get_option('research_english')
  local start = segmentation:get_current_start_position()
  local input = segmentation.input:sub(start + 1)
  local word = input:match(english and "^[A-Za-z][A-Za-z'-]*" or "^[A-Za-z][A-Za-z%-]*")
  if not word then return true end
  if not english and (not word:find('-', 1, true)
      or (start == 0 and (input:sub(1, 2) == 'cC' or input:sub(1, 2) == 'uU'))) then return true end
  local segment = Segment(start, start + #word)
  segment.tags = english and Set({'abc', 'research_english'})
      or Set({'abc', 'english_compound'})
  segmentation:add_segment(segment)
  return false
end

return M
