local M = {}
local navigation = {[0x2c]='Up', [0x2e]='Down', [0x2d]='Page_Up', [0x3d]='Page_Down'}
local native_navigation = {[0xff52]='Up', [0xff54]='Down',
                           [0xff55]='Page_Up', [0xff56]='Page_Down'}

local function plain(key)
  return not (key:release() or key:shift() or key:ctrl() or key:alt() or key:super())
end

local function ordinary(seg)
  return seg:has_tag('abc') and not seg:has_tag('u_lookup')
      and not seg:has_tag('reverse_lookup')
end

local function observe(env)
  local ctx = env.engine.context
  if ctx.input == '' then
    env.ever_later_page = false
  elseif not env.ever_later_page and ctx:has_menu() then
    local seg = ctx.composition:back()
    if ordinary(seg) and seg.selected_index >= env.engine.schema.page_size then
      env.ever_later_page = true
    end
  end
end

function M.init(env)
  env.ever_later_page = false
  env.selector = Component.Processor(env.engine, '', 'selector')
  env.update = env.engine.context.update_notifier:connect(function() observe(env) end)
end

function M.fini(env)
  env.update:disconnect()
  env.selector = nil
end

function M.is_navigation(key)
  return navigation[key.keycode] ~= nil and plain(key)
end

function M.func(key, env)
  observe(env)
  local code = key.keycode
  local ctx = env.engine.context
  if (code == 0xff09 or code == 0xff08) and plain(key)
      and env.engine.schema.schema_id == 'pc_research'
      and not ctx:get_option('ascii_mode') and not ctx:get_option('research_english')
      and not ctx.composition:empty() then
    local seg = ctx.composition:back()
    local confirmed = ctx.composition:toSegmentation():get_confirmed_position()
    if ordinary(seg) and not seg:has_tag('tool_calculator') and not seg:has_tag('tool_unicode')
        and confirmed > 0 and confirmed < #ctx.input then
      if code == 0xff09 and ctx.caret_pos == #ctx.input then
        -- Native word-right skips this boundary when wrapping from the end.
        ctx:confirm_previous_selection()
        ctx.caret_pos = confirmed
        return 1
      elseif code == 0xff08 and ctx.caret_pos > confirmed
          and ctx.input:sub(confirmed + 1):match('^[A-Za-z\'"; ]+$') then
        -- Edit the pending spelling without native selection undo or the
        -- editor reopening the selected segment when its final suffix goes.
        ctx:confirm_previous_selection()
        ctx:pop_input(1)
        return 1
      end
    end
  end
  local target = navigation[code] or native_navigation[code]
  if not target or not plain(key) then return 2 end
  if ctx:get_option('ascii_mode') or ctx.composition:empty() then return 2 end
  local seg = ctx.composition:back()
  local word = ordinary(seg)
  local unicode_move = seg:has_tag('tool_unicode') and (code == 0x2c or code == 0x2e)
  if not seg:has_tag('abc') and not seg:has_tag('u_lookup')
      and not unicode_move then return 2 end
  local has_menu = ctx:has_menu()
  if code == 0x2d and word then
    if not env.ever_later_page then
      -- Before the draft has visited a later page, '-' belongs to the word.
      if require('draft_limit').allow_context(ctx, env.engine.schema, '-') then
        ctx:push_input('-')
      end
      return 1
    elseif not has_menu then
      return 1
    end
  end
  if not has_menu then return 2 end
  -- Call the native selector directly, then observe its resulting selection.
  -- Native arrow/page actions do not emit Context update notifications.
  local result = env.selector:process_key_event(KeyEvent(target))
  observe(env)
  require('cn_preedit_spacing').refresh(ctx)
  return navigation[code] and 1 or result
end

return M
