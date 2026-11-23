-- Both language modes share one native English Memory and the same lookup engine.
local M, vocab_cache, extension_cache = {}, {}, {}
local index_module = require('en_index')
local dlc_module = require('en_dlc')
local scheme_data = require('scheme_data')

local function identity(code, text) return code .. '\t' .. text end

local function vocabulary(directory, words)
  if vocab_cache[directory] then return vocab_cache[directory] end
  local frequency = {}
  local file = assert(io.open(directory .. '/vocabulary.tsv', 'r'))
  local data = assert(file:read('*a'))
  file:close()
  for line in data:gmatch('[^\n]+') do
    local word, count = line:match('^([^\t]+)\t(%d+)')
    if word then frequency[word] = tonumber(count) end
  end
  -- The binary index already owns the same sorted, immutable vocabulary.
  -- Keep its word_id order and share the array with prefix lookup.
  local result = {words=words, frequency=frequency}
  vocab_cache[directory] = result
  return result
end

local function extensions(directory, vocab)
  if extension_cache[directory] then return extension_cache[directory] end
  local aliases, words, display = {}, {}, {}
  local file = assert(io.open(directory .. '/entries.tsv', 'r'))
  for line in file:lines() do
    local alias, code, text, shown, expansion, weight, parent_code, parent_text =
        line:match('^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)\t([^\t]*)\t([^\t]*)')
    if not aliases[alias] then aliases[alias] = {}; words[#words + 1] = alias end
    local group = aliases[alias]
    group[#group + 1] = {code=code, word=text, shown=shown, expansion=tonumber(expansion),
      frequency=tonumber(weight), parent=parent_code ~= '' and identity(parent_code, parent_text) or nil}
    if vocab.frequency[text] and code == text and alias == text and expansion == '0' then
      display[text] = shown
    end
  end
  file:close()
  table.sort(words)
  -- This small form table only resolves base/extension case collisions.
  -- A lowercase frequency row alone does not establish a lowercase spelling.
  local ordinary = {}
  local forms = assert(io.open(directory .. '/case_forms.tsv', 'r'))
  for line in forms:lines() do
    local word, valid = line:match('^([^\t]+)\t([01])')
    if word then ordinary[word] = valid == '1' end
  end
  forms:close()
  local result = {aliases=aliases, words=words, display=display, ordinary=ordinary}
  extension_cache[directory] = result
  return result
end

local function case_style(input)
  if input == input:lower() then return 'lower' end
  local letters = input:gsub('[^A-Za-z]', '')
  if #letters > 1 and input == input:upper() then return 'upper' end
  if input:sub(1,1):match('[A-Z]') and input:sub(2) == input:sub(2):lower() then return 'title' end
  return 'mixed'
end

local function ordinary_display(word, input, style)
  if style == 'upper' then return word:upper() end
  if style == 'title' then return word:sub(1,1):upper() .. word:sub(2) end
  return word
end

local function display(item, input, style)
  -- Acronym expansions keep their own spelling; GDP is not a request to shout
  -- Gross Domestic Product. Canonical brands honor explicit all-uppercase.
  if item.shown then
    return style == 'upper' and item.tier == 0 and item.expansion == 0
        and item.shown:upper() or item.shown
  end
  return ordinary_display(item.word, input, style)
end

local function prefix_words(words, prefix)
  local low, high = 1, #words + 1
  while low < high do
    local mid = (low + high) // 2
    if words[mid] < prefix then low = mid + 1 else high = mid end
  end
  return function()
    local word = words[low]
    if word and word:sub(1, #prefix) == prefix then low = low + 1; return word end
  end
end

local function order(a, b)
  if a.tier ~= b.tier then return a.tier < b.tier end
  if a.learned ~= b.learned then return a.learned end
  if a.quality ~= b.quality then return a.quality > b.quality end
  if a.edit ~= b.edit then return a.edit < b.edit end
  return a.id < b.id
end

local function native_entry(env, item)
  if item.entry then return item.entry end
  if env.mem:dict_lookup(item.code, false, 0) then
    for entry in env.mem:iter_dict() do
      if entry.text == item.word then return entry end
    end
  end
  if not item.optional then error('English lookup entry absent from native dictionary') end
  -- Optional catalogs use the same canonical code/text identity and Memory
  -- as dictionary-backed words. No per-package learning database is needed.
  local entry = DictEntry()
  entry.text, entry.custom_code, entry.weight = item.word, item.code .. ' ', 0
  return entry
end

local function lookup(input, env, chinese)
  local lower, style = input:lower(), case_style(input)
  local _, letters = input:gsub('[A-Za-z]', '')
  local allow_prefix = not chinese or letters >= 3
  local budget = chinese and (letters >= 4 and 1 or 0)
      or (letters < 3 and 0 or (letters < 5 and 1 or 2))
  local learned_prefix = {}
  if env.mem:user_lookup(lower, true) then
    for entry in env.mem:iter_user() do
      if env.vocab.frequency[entry.text] then learned_prefix[entry.text] = entry end
    end
  end
  local users, items = {}, {}
  local function learned(code, word)
    if env.vocab.frequency[word] and code == word and word:sub(1,#lower) == lower then
      return learned_prefix[word]
    end
    if not users[code] then
      local entries = {}
      if env.mem:user_lookup(code, false) then
        for entry in env.mem:iter_user() do entries[entry.text] = entry end
      end
      users[code] = entries
    end
    return users[code][word]
  end
  local function add(code, word, tier, edit, definition)
    if definition and definition.expansion == 1 then tier = math.max(tier, 1) end
    local id = identity(code, word)
    local old = items[id]
    if old and (old.tier < tier or (old.tier == tier and old.edit <= edit)) then return end
    local entry = learned(code, word)
    local frequency = env.vocab.frequency[word] or definition.frequency
    local shown = definition and definition.shown or env.ext.display[word]
    local item = {id=id, code=code, word=word, tier=tier, edit=edit,
      entry=entry, learned=entry ~= nil, quality=entry and entry.weight or frequency,
      shown=shown, expansion=definition and definition.expansion or 0,
      parent=definition and definition.parent, optional=definition and definition.optional}
    -- Corpus counts and user probabilities have different units. Keep the
    -- corpus contribution small; native learning supplies the promotion.
    item.score = (entry and (0.5 + math.exp(entry.weight)) or (-1 + math.log(1 + frequency) / 1000))
        - tier * 0.1
    items[id] = item
  end
  for word in prefix_words(env.vocab.words, lower) do
    if word == lower or allow_prefix then add(word, word, word == lower and 0 or 1, 0) end
  end
  local function add_alias(source, alias, tier, edit)
    for _, definition in ipairs(source.aliases[alias]) do
      add(definition.code, definition.word, tier, edit, definition)
    end
  end
  for alias in prefix_words(env.ext.words, lower) do
    if alias == lower or allow_prefix then add_alias(env.ext, alias, alias == lower and 0 or 1, 0) end
  end
  for alias in prefix_words(env.dlc.words, lower) do
    if alias == lower or allow_prefix then add_alias(env.dlc, alias, alias == lower and 0 or 1, 0) end
  end
  if budget > 0 and style ~= 'mixed' then
    for _, match in ipairs(env.index:suggest(lower, budget)) do
      if match.word:sub(1,#lower) ~= lower then add(match.word, match.word, 2, match.edit) end
    end
    for _, match in ipairs(env.ext_index:suggest(lower, budget)) do
      if match.word:sub(1,#lower) ~= lower then add_alias(env.ext, match.word, 2, match.edit) end
    end
    for _, match in ipairs(env.dlc.index:suggest(lower, budget)) do
      if match.word:sub(1,#lower) ~= lower then add_alias(env.dlc, match.word, 2, match.edit) end
    end
  end
  local ordered = {}
  for _, item in pairs(items) do ordered[#ordered + 1] = item end
  table.sort(ordered, order)
  local result, emitted = {}, {}
  local function append(item)
    if emitted[item.id] then return end
    local parent = item.parent and items[item.parent]
    if parent and parent.id ~= item.id and parent.tier <= item.tier and not emitted[parent.id] then
      result[#result + 1], emitted[parent.id] = parent, true
    end
    result[#result + 1], emitted[item.id] = item, true
  end
  for _, item in ipairs(ordered) do append(item) end
  -- A learned completion can advance without overtaking its exact word.
  -- Raise required predecessors rather than capping the learned candidate.
  for i = #result - 1, 1, -1 do
    result[i].score = math.max(result[i].score, result[i + 1].score + 0.000001)
  end
  return result, style
end

function M.init(env)
  local index_directory = scheme_data.directory('english_index', 'words.txt')
  local extension_directory = scheme_data.directory('english_extensions', 'entries.tsv')
  env.index = index_module.load(index_directory)
  env.vocab = vocabulary(index_directory, env.index.words)
  env.ext = extensions(extension_directory, env.vocab)
  env.ext_index = index_module.load(extension_directory)
  env.dlc = dlc_module.load(env.vocab, env.ext, env.engine)
  env.mem = Memory(env.engine, env.engine.schema, 'english_native')
  env.mem:memorize(function(commit)
    for _, entry in ipairs(commit:get()) do env.mem:update_userdict(entry, 1, '') end
    return true
  end)
end

function M.fini(env)
  env.mem:disconnect()
  env.mem, env.index, env.ext_index, env.vocab, env.ext, env.dlc = nil, nil, nil, nil, nil, nil
  collectgarbage('collect')
end

function M.func(input, seg, env, chinese)
  if input == '' then return end
  local pattern = chinese and '^[A-Za-z][A-Za-z%-]*$' or "^[A-Za-z][A-Za-z'%-]*$"
  env.mem:finish_session()
  local seen, ordinal = {}, 0
  if input:match(pattern) then
    local items, style = lookup(input, env, chinese)
    local function emit(item, text)
      if not seen[text] then
        local phrase = Phrase(env.mem, 'research_english', seg.start, seg._end, native_entry(env, item))
        phrase.preedit = input
        local comment = item.tier == 0 and '完整词' or (item.tier == 1 and '补全' or ('纠错 · ' .. item.edit))
        local shadow = ShadowCandidate(phrase:toCandidate(), 'research_english', text, comment)
        ordinal = ordinal + 1
        shadow.quality = chinese and item.score or (1000000 - ordinal)
        seen[text] = true
        yield(shadow)
      end
    end
    for _, item in ipairs(items) do
      local canonical = display(item, input, style)
      local ordinary = item.shown and item.code == item.word
          and (env.ext.ordinary[item.word] or env.dlc.ordinary[item.word]) and style ~= 'mixed'
          and ordinary_display(item.word, input, style)
      -- A complete vocabulary word identical to the draft precedes its
      -- canonical alias. This order is independent of shared word learning.
      -- Mixed case only matches an actual canonical spelling, with spaces
      -- omitted for aliases such as VSCode -> VS Code. Never invent WHere.
      local matches_case = style ~= 'mixed' or (item.shown
          and canonical:gsub(' ', ''):sub(1, #input) == input)
      if matches_case then
        if item.tier == 0 and ordinary == input then emit(item, ordinary) end
        emit(item, canonical)
        if ordinary then emit(item, ordinary) end
      end
    end
  end
  if not chinese and not seen[input] then
    local raw = Candidate('research_english', seg.start, seg._end, input, '原文')
    raw.preedit, raw.quality = input, 1000000 - ordinal - 1
    yield(raw)
  end
end

return M
