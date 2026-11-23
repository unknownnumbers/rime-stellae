-- SPDX-License-Identifier: GPL-3.0-only
-- A semicolon locks one syllable; a quote confirms the pending prefix.
local M = {}

function M.func(key, env)
  local code = key.keycode
  if (code ~= 0x22 and code ~= 0x27 and code ~= 0x3b and code ~= 0xffff) or key:release() or key:ctrl()
      or key:alt() or key:super()
      or ((code == 0xffff or code == 0x3b or code == 0x27) and key:shift())
      or env.engine.schema.schema_id ~= 'pc_research' then return 2 end
  local ctx = env.engine.context
  if ctx:get_option('ascii_mode') or ctx:get_option('research_english')
      or ctx.input == '' or ctx.composition:empty() then return 2 end
  local seg = ctx.composition:back()
  if not seg:has_tag('abc') or seg:has_tag('reverse_lookup')
      or seg:has_tag('u_lookup') or seg:has_tag('tool_calculator')
      or seg:has_tag('tool_unicode') then return 2 end

  local confirmed = ctx.composition:toSegmentation():get_confirmed_position()
  local caret = ctx.caret_pos
  local pending = ctx.input:sub(confirmed + 1)
  if not pending:match('^[a-z\'"; ]+$') then return 2 end
  if code == 0xffff then
    if caret < confirmed or caret >= #ctx.input
        or not pending:find('[";]') then return 2 end
    -- A forward edit can change the lock beyond a middle caret while leaving
    -- its active input prefix unchanged. Discard its cached menu before the
    -- normal delete notification recomposes the new draft once.
    ctx:clear_non_confirmed_composition()
    ctx:delete_input(1)
    return 1
  end
  if caret <= confirmed then return 2 end
  local left = ctx.input:sub(confirmed + 1, caret)
  -- An unknown spelling may still be closed and edited. Only the ordinary
  -- Chinese draft shape and a nonempty block immediately to the left matter.
  if code == 0x27 then
    -- Keep a separator after a quote inside the pending spelling instead of
    -- letting the punctuator submit the just-confirmed native prefix.
    if left:sub(-1) ~= '"' then return 2 end
  elseif not left:match('[a-z]+$') then return 2 end
  local marker = string.char(code)
  if require('draft_limit').allow_context(ctx, env.engine.schema, marker) then
    ctx:push_input(marker)
  end
  return 1
end

M.segmentor = {}

function M.segmentor.func(segmentation, env)
  local ctx = env.engine.context
  if env.engine.schema.schema_id ~= 'pc_research'
      or ctx:get_option('ascii_mode') or ctx:get_option('research_english') then return true end
  local start = segmentation:get_current_start_position()
  local input = segmentation.input:sub(start + 1)
  -- Use only the supplied segmentation input, which may stop at a middle
  -- caret. Unmarked spelling and other input tools retain their segmentors.
  local word = input:match('^[a-z\'"; ]+')
  local marker = word and word:find('[";]')
  if not marker or not word:sub(1, marker - 1):match('[a-z]$') then return true end
  local segment = Segment(start, start + #word)
  segment.tags = Set({'abc'})
  segmentation:add_segment(segment)
  return false
end

return M
