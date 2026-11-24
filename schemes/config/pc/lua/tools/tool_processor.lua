local M = {}

local function selected_prefix(ctx, finish)
  local parts = {}
  for _, seg in ipairs(ctx.composition:toSegmentation():get_segments()) do
    if seg._end > finish then break end
    local candidate = seg:get_selected_candidate()
    parts[#parts + 1] = candidate and candidate.text or ctx.input:sub(seg.start + 1, seg._end)
  end
  return table.concat(parts)
end

function M.func(key, env)
  local ctx = env.engine.context
  if ctx:get_option('research_english') or ctx:get_option('ascii_mode')
      or key:release() or key:ctrl() or key:alt() or key:super()
      or ctx.composition:empty() then return 2 end
  local seg = ctx.composition:back()
  if not seg:has_tag('tool_calculator') and not seg:has_tag('tool_unicode') then return 2 end
  local code = key.keycode
  if seg:has_tag('tool_unicode') and ctx:has_menu() and not key:shift()
      and (code == 0x2c or code == 0x2e) then
    -- Unicode has no decimal point or argument separator. Let the shared
    -- candidate navigator consume these keys before punctuation processing.
    return 2
  elseif code == 0xff0d or code == 0xff8d then
    if seg:has_tag('tool_calculator') then
      local candidate = ctx:get_selected_candidate()
      if candidate and candidate.type == 'tool_calc' then
        ctx:confirm_current_selection()
      else
        local expression = ctx.input:sub(seg.start + 3)
        if expression ~= '' then
          -- Translation already evaluated this draft. Reuse its error text;
          -- do not evaluate random functions again when committing.
          local message = ctx:get_property('auxiliary_text'):gsub('^算式', '')
          env.engine:commit_text(selected_prefix(ctx, seg.start) .. expression .. ' ' .. message)
          ctx:clear()
        end
      end
    else
      local raw = selected_prefix(ctx, seg.start) .. ctx.input:sub(seg.start + 1)
      env.engine:commit_text(raw)
      ctx:clear()
    end
    return 1
  elseif code == 0x20 then
    -- An empty menu is a hint, never a selectable error/raw-input candidate.
    local candidate = ctx:get_selected_candidate()
    if candidate and (candidate.type == 'tool_calc' or candidate.type == 'tool_unicode') then
      ctx:confirm_current_selection()
    end
    return 1
  elseif code >= 0x21 and code <= 0x7e then
    local char = string.char(code)
    -- Non-code punctuation must not drop Unicode into the Chinese punctuator.
    -- Letters still follow normal segmentation, including Up/Upsilon names.
    if seg:has_tag('tool_unicode') and char:match('%p') then return 1 end
    ctx:push_input(char)
    return 1
  end
  return 2
end

return M
