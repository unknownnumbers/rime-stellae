-- English submission, internal punctuation and editing of one pending word.
-- Candidate deletion/frequency reset remains the native Ctrl/Shift+Delete.
local candidate_keys = require('candidate_keys')
local M = {}

local function edit_word(key, ctx)
  local code = key.keycode
  if key:shift() or (code ~= 0xff51 and code ~= 0xff53 and code ~= 0xff08) then return 2 end
  local start = ctx.composition:toSegmentation():get_confirmed_position()
  local input, caret = ctx.input, ctx.caret_pos
  if start > 0 and caret == start and start == #input then return 1 end
  -- Space commits a word. Only the pending English remainder is ours to edit;
  -- selected Chinese/English segments retain their raw codes and candidates.
  if caret < start or not input:sub(start + 1):match("^[A-Za-z][A-Za-z'%-]*$") then return 2 end
  ctx:confirm_previous_selection() -- BeginEditing marker; does not commit.
  if code == 0xff51 then
    if caret > start then ctx.caret_pos = start end
  elseif code == 0xff53 then
    if caret < #input then ctx.caret_pos = #input end
  elseif caret > start then
    ctx:pop_input(caret - start)
  end
  return 1
end

function M.func(key, env)
  local ctx = env.engine.context
  if ctx:get_option('ascii_mode') or not ctx:get_option('research_english') or key:release()
      or key:alt() or key:super() then return 2 end
  if not ctx:is_composing() then return 2 end
  if key:ctrl() then return edit_word(key, ctx) end
  -- The shared processor owns draft-scoped navigation and literal hyphens.
  if candidate_keys.is_navigation(key) then return 2 end
  local code = key.keycode
  if code == 0x27 or code == 0x2d then
    local before = ctx.input:sub(1, ctx.caret_pos)
    if before:match('[A-Za-z]$') then
      ctx:push_input(string.char(code))
      return 1
    end
  end
  if code == 0x20 then
    -- Preserve native partial selection when the caret is inside a draft.
    if not ctx:confirm_current_selection() then ctx:commit() end
    if not ctx:is_composing() then env.engine:commit_text(' ') end
    return 1
  end
  if code >= 0x21 and code <= 0x7e then
    local character = string.char(code)
    if character:match('%p') then
      ctx:confirm_current_selection()
      if ctx:is_composing() then ctx:commit() end
      env.engine:commit_text(character)
      return 1
    end
  end
  return 2
end

return M
