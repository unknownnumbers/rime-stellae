-- Export query information independently from the shortened UI comment.
-- This processor belongs before tool_processor / jp_v_processor.
local M = {}
-- Engine sessions in the same process share the immutable deployed tables.
-- Like u_translator's readings, a service restart refreshes deployed data.
local stroke_cache, reading_cache = {}, {}

local function exact_ctrl_return(key)
  return (key.keycode == 0xff0d or key.keycode == 0xff8d)
      and key:ctrl() and not key:shift() and not key:alt()
      and not key:super() and not key:release()
end

local function exact_shift_return(key)
  return (key.keycode == 0xff0d or key.keycode == 0xff8d)
      and key:shift() and not key:ctrl() and not key:alt()
      and not key:super() and not key:release()
end

local function exact_comment_return(key)
  return (key.keycode == 0xff0d or key.keycode == 0xff8d)
      and key:ctrl() and key:shift() and not key:alt()
      and not key:super() and not key:release()
end

local function readable_japanese_comment(comment)
  return ((comment or ''):gsub('^%[jp:[^%]]*%]', '')
    :gsub(' | _訓 ', ' | 訓 '):gsub(' | _音 ', ' | 音 '):gsub(' | _中 ', ' | 中 '))
end

local function load_tsv(path)
  local result = {}
  local file = io.open(path, 'r')
  if not file then return result end
  for line in file:lines() do
    local text, information = line:match('^([^\t]+)\t([^\t\r]+)')
    if text then result[text] = information end
  end
  file:close()
  return result
end

function M.init(env)
  env.query_info_dir = rime_api.get_user_data_dir()
  -- The ordinary Chinese scheme need not load the Japanese dictionaries.
  local schema = env.engine.schema
  if schema.schema_id == 'jp_sela' or schema.config:get_bool('query_info/japanese_v') then
    env.query_info_jp = require('jp_v')
  end
end

function M.fini(env)
  env.query_info_jp = nil
end

function M.information(text, kind, env)
  if kind == 'unicode' then
    local values = {}
    for _, cp in utf8.codes(text) do values[#values + 1] = string.format('U+%04X', cp) end
    return table.concat(values, ' ')
  elseif kind == 'reading' then
    local readings = reading_cache[env.query_info_dir]
    if not readings then
      readings = load_tsv(require('scheme_data').path('u_readings.tsv', true))
      reading_cache[env.query_info_dir] = readings
    end
    return readings[text] or '*讀音未收錄'
  end
  local strokes = stroke_cache[env.query_info_dir]
  if not strokes then
    strokes = load_tsv(require('scheme_data').path('query_strokes.tsv', true))
    stroke_cache[env.query_info_dir] = strokes
  end
  return strokes[text] or '筆畫未收錄'
end

-- Snapshot every byte range and the already selected prefix before clearing.
-- Offsets are librime's zero-based byte offsets, not UTF-8 character counts.
function M.snapshot(ctx, candidate)
  local parts = {}
  for _, seg in ipairs(ctx.composition:toSegmentation():get_segments()) do
    if seg._end > candidate.start then break end
    local prior = seg:get_selected_candidate()
    parts[#parts + 1] = prior and prior.text or ctx.input:sub(seg.start + 1, seg._end)
  end
  return {prefix = table.concat(parts), text = candidate.text,
          start = candidate.start, finish = candidate._end,
          tail = ctx.input:sub(candidate._end + 1)}
end

function M.submit(ctx, candidate, kind, env)
  local state = M.snapshot(ctx, candidate)
  local information = M.information(state.text, kind, env)
  env.engine:commit_text(state.prefix .. state.text .. ' (' .. information .. ')')
  -- Deliberately do not confirm a synthetic annotated candidate: parentheses
  -- and exported metadata must never become a learned dictionary phrase.
  ctx:clear()
  if state.tail ~= '' then ctx:push_input(state.tail) end
end

function M.func(key, env)
  local ctrl, shift = exact_ctrl_return(key), exact_shift_return(key)
  local comment_return = exact_comment_return(key)
  if not ctrl and not shift and not comment_return then return 2 end
  local ctx = env.engine.context
  if ctx:get_option('ascii_mode') or ctx:get_option('research_english') then return 2 end

  local jp = env.query_info_jp
  local state = jp and jp.parse(ctx)
  if state and state.active then
    if comment_return then
      local candidate = ctx:get_selected_candidate()
      if candidate then
        jp.submit(ctx, candidate, readable_japanese_comment(candidate.comment), env.engine, false)
      end
      return 1
    end
    -- Whole-word V has sourced readings without on/kun classification.
    -- Both modifiers export that same complete list.
    local candidate = ctx:get_selected_candidate()
    if candidate then
      local group = state.mode == 'char' and (shift and 'on' or 'kun') or nil
      local text, tail = jp.reading_parts(candidate)
      local description = jp.describe(text, state.mode, group)
      jp.submit(ctx, candidate, description.commit .. tail, env.engine, text)
    end
    return 1
  end

  -- Shift is a new Japanese-char query action only. All other schemes and
  -- tools keep their native Shift+Return CommitScript behavior (e.g. nv).
  if not ctrl then return 2 end

  if ctx.composition:empty() then return 2 end
  local seg = ctx.composition:back()
  local candidate = ctx:get_selected_candidate()
  local raw = ctx.input:sub(seg.start + 1, seg._end)
  local kind
  if seg:has_tag('tool_unicode') and raw:match('^U%x*$') then
    kind = 'unicode'
  elseif seg:has_tag('u_lookup') or seg:has_tag('reverse_lookup') then
    local body, marker = raw:match("^uU([a-z]*)(U?)'?$" )
    if body then kind = marker == 'U' and 'reading' or 'stroke' end
  end
  if not kind then return 2 end
  if candidate then M.submit(ctx, candidate, kind, env) end
  -- Bare prefixes / missing candidates stay as a draft instead of falling
  -- through to native CommitScript and leaking a control prefix.
  return 1
end

return M
