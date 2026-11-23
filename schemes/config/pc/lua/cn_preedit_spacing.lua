-- Normal suffix boundaries are display data, never new input or candidates.
local mixed = require('mixed_translator')
local M = {}
local exact = require('cn_exact_spelling')
local property = 'cn_preedit_spacing'
local owner_property, next_owner, owners = 'cn_preedit_spacing_owner', 0, {}
local chinese = {cn_full=true,phrase=true,user_phrase=true,sentence=true,completion=true}

-- Same cost recurrence as cn_translator. A successor is recorded only when a
-- complete normal path exists; mixed-word costs alone supply no such path.
function M.normal_tail_cost(input, env, cache)
  if cache.tail_cost then return cache.tail_cost end
  local plan = cache.exact_plan or exact.parse(input)
  local costs, following, counts = {[#input + 1]=0}, {}, {[#input + 1]=0}
  for position = #input, 1, -1 do
    local best
    if not plan or exact.unmarked(plan, position, #input) then
      best = mixed.continuation_cost(input, position, costs)
    end
    local best_next, best_count
    for length = 1, math.min(env.normal_max_length, #input - position + 1) do
      local kind = env.normal_spellings[input:sub(position, position + length - 1)]
      if kind then
        local next_position
        if plan then next_position = exact.advance(plan, position, length, kind)
        else
          next_position = position + length
          while input:sub(next_position, next_position) == "'"
              or input:sub(next_position, next_position) == ' ' do next_position = next_position + 1 end
        end
        local tail = next_position and costs[next_position]
        if tail then
          local cost = kind + tail
          local count = counts[next_position] and counts[next_position] + 1
          if best == nil or cost < best then
            best, best_next, best_count = cost, count and next_position, count
          elseif cost == best and count and (not best_count or count < best_count
              or (count == best_count and next_position > best_next)) then
            best_next, best_count = next_position, count
          end
        end
      end
    end
    costs[position], following[position], counts[position] = best, best_next, best_count
  end
  cache.tail_cost, cache.tail_next, cache.tail_count = costs, following, counts
  return costs
end

local function set(ctx, value)
  if ctx:get_property(property) ~= value then ctx:set_property(property, value) end
end

-- Reuse the query DP only if it covers the full current suffix byte-for-byte.
-- A query before a middle caret must not replace a cached full-draft path.
function M.record(env, input, start, cache)
  local state = env.cn_preedit_spacing_state
  local raw = env.engine.context.input
  if state and raw:sub(start + 1) == input and cache.tail_next then
    state.raw, state.start = raw, start
    state.cache = {tail_cost=cache.tail_cost,tail_next=cache.tail_next,tail_count=cache.tail_count}
  end
end

function M.publish(env)
  local ctx, state = env.engine.context, env.cn_preedit_spacing_state
  if not state then return end
  local raw = ctx.input
  if raw == '' or ctx:get_option('ascii_mode') or ctx:get_option('research_english')
      or env.only_chinese or env.engine.schema.schema_id == 'jp_sela'
      or ctx.composition:empty() or not ctx:has_menu() then
    set(ctx, '')
    return
  end
  local seg = ctx.composition:back()
  if not seg:has_tag('abc') or seg:has_tag('reverse_lookup') or seg:has_tag('u_lookup')
      or seg:has_tag('tool_calculator') or seg:has_tag('tool_unicode') then
    set(ctx, '')
    return
  end
  local candidate = ctx:get_selected_candidate()
  if not candidate or not chinese[candidate:get_genuine().type]
      or candidate.start < seg.start or candidate._end >= #raw then
    set(ctx, '')
    return
  end
  local body = raw:sub(seg.start + 1)
  if not body:match('^[a-z\'"; ]+$') then set(ctx, ''); return end
  if state.raw ~= raw or state.start ~= seg.start then
    local cache = {}
    M.normal_tail_cost(body, env, cache)
    state.raw, state.start, state.cache = raw, seg.start, cache
  end
  local cache, position, breaks = state.cache, candidate._end - seg.start + 1, {}
  while body:sub(position, position) == "'" or body:sub(position, position) == ' '
      or body:sub(position, position) == '"' or body:sub(position, position) == ';' do
    position = position + 1
  end
  if not cache.tail_count[position] then set(ctx, ''); return end
  while position <= #body do
    local before, after = body:sub(position - 1, position - 1), body:sub(position, position)
    if before:match('[a-z]') and after:match('[a-z]') then
      breaks[#breaks + 1] = seg.start + position - 1
    end
    position = cache.tail_next[position]
  end
  if #breaks == 0 then set(ctx, ''); return end
  set(ctx, candidate.start .. ':' .. candidate._end .. ':' .. #raw .. ':' .. ctx.caret_pos
    .. '|' .. table.concat(breaks, ','))
end

function M.init(env)
  next_owner = next_owner + 1
  local owner = tostring(next_owner)
  env.cn_preedit_spacing_state = {owner=owner}
  owners[owner] = env
  env.engine.context:set_property(owner_property, owner)
  env.cn_preedit_spacing_state.connection = env.engine.context.update_notifier:connect(function()
    M.publish(env)
  end)
  env.cn_preedit_spacing_state.option_connection = env.engine.context.option_update_notifier:connect(function(_, name)
    if name == 'ascii_mode' or name == 'research_english' then M.publish(env) end
  end)
end

-- Native selector actions can update selected_index without update_notifier.
-- The per-Context owner id reaches only that Context's active translator env.
function M.refresh(ctx)
  local env = owners[ctx:get_property(owner_property)]
  if env then M.publish(env) end
end

-- Borrow the current translator's dictionary-only Memory for native Phrases.
function M.decoder(ctx)
  local env = owners[ctx:get_property(owner_property)]
  return env and env.decoder
end

function M.fini(env)
  local state = env.cn_preedit_spacing_state
  if state then
    state.connection:disconnect()
    state.option_connection:disconnect()
    owners[state.owner] = nil
    local ctx = env.engine.context
    if ctx:get_property(owner_property) == state.owner then
      ctx:set_property(owner_property, '')
      set(ctx, '')
    end
  end
  env.cn_preedit_spacing_state = nil
end

return M
