-- Bound unconfirmed spelling without committing or clearing the draft.
-- A limit consumes only additional spelling keys; it never commits or clears.
local M = {}
M.defaults = {chinese=48, english=64, calculator=256, radical=64,
              unicode=6, japanese=48}

function M.shape(raw, schema_id, english, limits, confirmed)
  limits = limits or M.defaults
  confirmed = confirmed or 0
  local pending = raw:sub(confirmed + 1)
  local mode, prefix, suffix = 'chinese', 0, 0
  if english then mode = 'english'
  elseif schema_id == 'jp_sela' then
    mode = 'japanese'
    if raw:sub(1, 2) == 'vV' or raw:sub(1, 2) == 'qQ' or raw:sub(1, 2) == 'xX' then
      prefix = math.max(0, 2 - confirmed)
      local last = raw:sub(-1)
      -- Only vV has a reading suffix. qQ/xX keep the same two-byte prefix
      -- throughout this draft without reserving an invented closing marker.
      if raw:sub(1, 2) == 'vV' and #raw > 2
          and (last == 'v' or last == 'V') then suffix = 1 end
    elseif (raw:sub(1, 1) == 'v' and raw:sub(1, 2) ~= 'vu')
        or raw:sub(1, 1) == 'q' then prefix = math.max(0, 1 - confirmed) end
  elseif confirmed == 0 and raw:sub(1, 2) == 'cC' then mode, prefix = 'calculator', 2
  elseif confirmed == 0 and raw:sub(1, 2) == 'uU' then
    mode, prefix = 'radical', 2
    if #pending > 2 and pending:sub(-1) == 'U' then suffix = 1 end
  elseif confirmed == 0 and raw:match('^U%x*$') then mode, prefix = 'unicode', 1 end
  return {mode=mode, prefix=prefix, suffix=suffix,
          body=#pending-prefix-suffix, limit=limits[mode], confirmed=confirmed}
end

function M.allowed(raw, caret, character, schema_id, english, limits, confirmed)
  local proposed = raw:sub(1, caret) .. character .. raw:sub(caret + 1)
  -- Editing before the confirmed boundary reopens that portion. Do not give
  -- inserted letters a hidden allowance inside an already selected segment.
  local start = math.min(confirmed or 0, caret)
  local shape = M.shape(proposed, schema_id, english, limits, start)
  return shape.body <= shape.limit, shape
end

function M.init(env)
  env.limits = {}
  local config = env.engine.schema.config
  env.spelling = (config:get_string('speller/alphabet') or '')
      .. (config:get_string('speller/delimiter') or '')
  for mode, fallback in pairs(M.defaults) do
    env.limits[mode] = config:get_int('draft_limits/' .. mode) or fallback
  end
end

function M.allow_context(ctx, schema, character)
  local limits = {}
  for mode, fallback in pairs(M.defaults) do
    limits[mode] = schema.config:get_int('draft_limits/' .. mode) or fallback
  end
  return M.allowed(ctx.input, ctx.caret_pos, character, schema.schema_id,
                   ctx:get_option('research_english'), limits,
                   ctx.composition:toSegmentation():get_confirmed_position())
end

function M.func(key, env)
  local ctx = env.engine.context
  if key:release() or key:ctrl() or key:alt() or key:super()
      or ctx:get_option('ascii_mode') then return 2 end
  local code = key.keycode
  -- Space, selection numbers and navigation are not spelling in ordinary input.
  if code < 0x21 or code > 0x7e then return 2 end
  local raw, english = ctx.input, ctx:get_option('research_english')
  local confirmed = ctx.composition:toSegmentation():get_confirmed_position()
  local character = string.char(code)
  local shape = M.shape(raw, env.engine.schema.schema_id, english, env.limits, confirmed)
  -- PC's navigator decides whether '-' pages or inserts a hyphen. Its
  -- literal branch applies allow_context. JP retains its existing page keys.
  if character == '-' and shape.mode ~= 'calculator' then
    local schema_id = env.engine.schema.schema_id
    if schema_id == 'pc_research' then return 2 end
    if schema_id == 'jp_sela' and not key:shift()
        and ctx:has_menu() then return 2 end
  end
  local spelling = env.spelling:find(character, 1, true) ~= nil
    or (english and (character == "'" or character == '-'))
    or (shape.mode == 'calculator')
    or (shape.mode == 'unicode' and character:match('%x') ~= nil)
  if not spelling then return 2 end
  local allowed = M.allowed(raw, ctx.caret_pos, character,
                           env.engine.schema.schema_id, english, env.limits, confirmed)
  return allowed and 2 or 1
end

return M
