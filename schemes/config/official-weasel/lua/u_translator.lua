-- Native literal and component lookup; u candidates never learn entries.
local M, reading_cache = {}, {}

local function pronunciation(text)
  local path = require('scheme_data').path('u_readings.tsv')
  local readings = reading_cache[path]
  if not readings then
    readings = {}
    local file = assert(io.open(path, 'r'))
    for line in file:lines() do
      local character, value = line:match('^([^\t]+)\t(.+)$')
      if character then readings[character] = value end
    end
    file:close()
    reading_cache[path] = readings
  end
  return readings[text] or '讀音未收錄'
end

local function display_spelling(code)
  return (code:gsub('[a-z]+', function(syllable)
    return (syllable:gsub('([ei])ng$', '%1n'))
  end))
end

local function advance(s)
  s.head = s.next and s.next(s.state) or nil
  -- Script results are longest-span first. Once shorter, no later result
  -- covers the query. Never wrap a partial match around the whole u input.
  if s.head and s.required_end and s.head._end ~= s.required_end then
    s.head = nil
  end
end

local function stream(translator, code, seg, name, abbreviated, required_end)
  local s = {name=name, abbreviated=abbreviated, required_end=required_end}
  s.translation = translator:query(code, seg)
  if s.translation then
    s.next, s.state = s.translation:iter()
    advance(s)
  end
  return s
end

local function rank(s, prefer_stroke)
  local literal = not s.abbreviated and s.head.type ~= 'completion'
  local source = (s.name == 'stroke') == prefer_stroke and 0 or 1
  -- Keep the existing exact/source priority. Within the radical remainder,
  -- complete component coverage precedes unfinished whole-code completion.
  return (literal and 0 or 10) + source * 3 + (s.abbreviated and 0 or 1)
end

function M.init(env)
  env.stroke = assert(Component.Translator(env.engine, '', 'table_translator@research_stroke'))
  env.radical = assert(Component.Translator(env.engine, '', 'table_translator@research_radical'))
  env.parts = assert(Component.Translator(env.engine, '', 'script_translator@research_radical_parts'))
  env.radical_codes = Memory(env.engine, env.engine.schema, 'research_radical')
end

function M.fini(env)
  env.radical_codes:disconnect()
  env.radical_codes = nil
  env.stroke, env.radical, env.parts, env.traditional = nil, nil, nil, nil
  collectgarbage('collect')
end

function M.func(input, seg, env)
  if seg.start ~= 0 or env.engine.context:get_option('research_english') then return end
  local code, marker = input:match("^uU([a-z]+)(U?)'?$")
  if not code then return end
  local show_readings = marker == 'U'

  local query_end = show_readings and (seg.start + 2 + #code) or seg._end
  local query_seg = Segment(seg.start, query_end)
  query_seg.tags = Set({'u_lookup'})
  local parts_end = seg.start + 2 + #code
  local parts_seg = Segment(seg.start + 2, parts_end)
  parts_seg.tags = Set({'u_lookup'})
  local streams = {
    stream(env.stroke, code, query_seg, 'stroke'),
    stream(env.radical, code, query_seg, 'radical'),
    stream(env.parts, code, parts_seg, 'radical', true, parts_end),
  }
  local prefer_stroke = code:match('^[hspnz]+$') ~= nil
  local traditional = not env.engine.context:get_option('simplification')
  if traditional and not env.traditional then
    env.traditional = assert(Opencc('s2t.json'))
  end
  local seen, ordinal = {}, 0
  while true do
    local current, current_rank
    for _, s in ipairs(streams) do
      if s.head then
        local r = rank(s, prefer_stroke)
        if not current or r < current_rank then current, current_rank = s, r end
      end
    end
    if not current then break end
    local native = current.head
    local forms = traditional and {env.traditional:convert_text(native.text), native.text}
                                 or {native.text}
    for _, text in ipairs(forms) do
      if not seen[text] then
        seen[text] = true
        ordinal = ordinal + 1
        local completion = native.type == 'completion'
        local suffix = current.abbreviated and '_abbreviation' or (completion and '_completion' or '')
        local label = current.name == 'stroke' and '笔画' or '拆字'
        local comment = label .. (current.abbreviated and ' · 简拼' or (completion and ' · 补全' or ''))
        local hint = native.comment
        if current.name == 'radical' then
          if current.abbreviated then
            hint = display_spelling(hint)
          elseif completion then
            -- Rebuild the tail from the complete code: native offsets count
            -- dictionary apostrophes and the g removed by our input rules.
            local full = table.concat(env.radical_codes:decode(native:get_genuine():to_phrase().code))
            full = display_spelling(full):gsub("'", '')
            hint = '~' .. full:sub(#code + 1)
          end
        end
        if hint ~= '' then comment = comment .. ' ' .. hint end
        -- Look up the actual displayed form after s2t conversion. The wrapper
        -- still consumes the whole input, including the optional U marker.
        if show_readings then comment = pronunciation(text) end
        local candidate = Candidate('u_' .. current.name .. suffix, seg.start, seg._end, text, comment)
        candidate.preedit = input
        candidate.quality = 1000000 - ordinal
        yield(candidate)
      end
    end
    advance(current)
  end
end

return M
