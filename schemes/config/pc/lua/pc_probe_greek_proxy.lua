-- Native translator owns learning for the isolated Greek and math symbol names.
local M = {}
local names = {
  'alpha','beta','gamma','delta','epsilon','zeta','eta','theta',
  'iota','kappa','lambda','mu','nu','xi','omicron','pi','rho',
  'sigma','tau','upsilon','phi','chi','psi','omega'
}
local math_symbols = {
  {'partial','∂'}, {'nabla','∇'}, {'int','∫'}, {'infty','∞'},
  {'subset','⊂'}, {'in','∈'}, {'to','→'}, {'leq','≤'}, {'geq','≥'},
  {'ell','ℓ'}, {'cap','∩'}, {'cup','∪'}, {'times','×'}, {'div','÷'},
  {'pm','±'}, {'square','□'}, {'mp','∓'}, {'wedge','∧'}, {'vee','∨'},
  {'oplus','⊕'}, {'otimes','⊗'}, {'lnot','¬'},
  {'forall','∀'}, {'exists','∃'}, {'circ','∘'}, {'backsim','∽'},
  {'angle','∠'}, {'triangle','△'}, {'Vert','‖'}, {'vert','|'},
  {'langle','⟨'}, {'rangle','⟩'}, {'equiv','≡'}, {'because','∵'},
  {'therefore','∴'}, {'Rightarrow','⇒'}, {'Leftrightarrow','⇔'},
  {'rightharpoonup','⇀'}, {'perp','⟂'}, {'complement','∁'}, {'ast','∗'},
  {'sqrt','√'},
}

-- Unrestricted Damerau-Levenshtein distance, ASCII names only.
local function distance(a, b)
  local m, n, inf = #a, #b, #a + #b
  local d, last = {}, {}
  for i = 0, m + 1 do d[i] = {} end
  d[0][0] = inf
  for i = 0, m do d[i + 1][0], d[i + 1][1] = inf, i end
  for j = 0, n do d[0][j + 1], d[1][j + 1] = inf, j end
  for i = 1, m do
    local previous_match = 0
    for j = 1, n do
      local ai, bj = a:sub(i,i), b:sub(j,j)
      local previous_i, previous_j = last[bj] or 0, previous_match
      local cost = 1
      if ai == bj then cost, previous_match = 0, j end
      d[i + 1][j + 1] = math.min(
        d[i][j] + cost, d[i + 1][j] + 1, d[i][j + 1] + 1,
        d[previous_i][previous_j] + (i - previous_i - 1) + 1 + (j - previous_j - 1))
    end
    last[a:sub(i,i)] = i
  end
  return d[m + 1][n + 1]
end
M.distance = distance

function M.init(env)
  env.unified = env.engine.schema.config:get_bool('probe/unified_memory') or false
  local class = env.unified and 'script_translator@translator' or 'table_translator@research_greek'
  env.native = Component.Translator(env.engine, '', class)
  assert(env.native, 'Installed binding lacks native translator proxy')
end

function M.fini(env)
  env.native = nil
  -- Release the native Memory before the engine's context is destroyed.
  collectgarbage('collect')
end

function M.func(input, seg, env)
  if env.engine.context:get_option('research_english') then return end
  local base = env.unified and not env.only_greek and env.native:query(input, seg) or nil
  if not input:match('^[A-Za-z]+$') then
    if base then for candidate in base:iter() do yield(candidate) end end
    return
  end
  local items, seen = {}, {}
  local function is_greek(text)
    local ok, length = pcall(utf8.len, text)
    if not ok or length ~= 1 then return false end
    local code = utf8.codepoint(text)
    return code >= 0x370 and code <= 0x3ff
  end
  local function collect(query, edits, kind, symbol)
    local native_query = env.code_prefix == '~g~' and (query:sub(1, -2) .. '~') or query
    local translation = env.native:query(native_query, seg)
    if not translation then return end
    for candidate in translation:iter() do
      if env.unified and candidate._end < seg.start + #native_query then break end
      -- Some names share the internal prism code (pi/pm and mu/mp).
      -- A math query must return its own symbol; Greek queries stay Greek-only.
      local matches = symbol and candidate.text == symbol
          or (not symbol and (not env.unified or is_greek(candidate.text)))
      if matches and not seen[candidate.text] then
        seen[candidate.text] = true
        -- A corrected canonical query can be longer than the raw input.
        candidate._end = seg._end
        candidate.preedit = input
        if edits > 0 then
          candidate = ShadowCandidate(candidate, candidate.type, candidate.text,
                                      query .. ' · 纠错')
        end
        -- The prefix prior belongs to unlearned static entries only.
        -- Native user phrases keep their learned comparison.
        local genuine = candidate:get_genuine()
        local prefix_penalty = env.unified and query ~= input and edits == 0
            and genuine.type ~= 'user_phrase' and 1 or 0
        items[#items + 1] = {candidate=candidate, kind=kind,
                             score=candidate.quality - edits * 0.05 - prefix_penalty}
      end
    end
  end
  -- Native exact and genuine prefix results are collected first.
  if env.unified then
    local capitalized = input:sub(1,1):match('[A-Z]') ~= nil
    for _, name in ipairs(names) do
      local canonical = capitalized and (name:sub(1,1):upper() .. name:sub(2)) or name
      if canonical:sub(1,#input) == input then collect(canonical, 0, 0) end
    end
  else
    collect(input, 0, 0)
  end
  local capitalized = input:sub(1,1):match('[A-Z]') ~= nil
  for _, entry in ipairs(math_symbols) do
    local name, symbol = entry[1], entry[2]
    if name:sub(1,#input) == input then
      collect(name, 0, 0, symbol)
    elseif #input >= 4 and #name >= 4
        and capitalized == (name:sub(1,1):match('[A-Z]') ~= nil) then
      -- LaTeX names are case-sensitive: Vert and vert name different symbols.
      local edits = distance(input, name)
      if edits > 0 and edits <= 2 then collect(name, edits, 1, symbol) end
    end
  end
  if #input >= 4 then
    local capitalized = input:sub(1,1):match('[A-Z]') ~= nil
    for _, name in ipairs(names) do
      local canonical = capitalized and (name:sub(1,1):upper() .. name:sub(2)) or name
      if #canonical >= 4 and canonical:sub(1,#input) ~= input then
        local edits = distance(input, canonical)
        if edits > 0 and edits <= 2 then collect(canonical, edits, 1) end
      end
    end
  end
  table.sort(items, function(a,b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    if a.score ~= b.score then return a.score > b.score end
    return a.candidate.text < b.candidate.text
  end)
  -- One scalar ordering prevents cycles when native merger compares Chinese.
  local previous_quality = math.huge
  for _, item in ipairs(items) do
    item.candidate.quality = math.min(item.score, previous_quality - 0.000001)
    previous_quality = item.candidate.quality
  end
  if not env.unified or env.only_greek then
    for _, item in ipairs(items) do yield(item.candidate) end
    return
  end
  if #items == 0 then
    if base then for candidate in base:iter() do yield(candidate) end end
    return
  end
  -- Sort only the full-span block; leave shorter native candidates lazy.
  -- Normal Chinese queries with no Greek match bypass this path completely.
  local full, iterator, iterator_state, current = {}, nil, nil, nil
  if base then
    iterator, iterator_state = base:iter()
    current = iterator(iterator_state)
    while current and current._end == seg._end do
      if not (is_greek(current.text) and seen[current.text]) then
        full[#full + 1] = {candidate=current, ordinal=#full + 1}
      end
      current = iterator(iterator_state)
    end
  end
  for _, item in ipairs(items) do full[#full + 1] = {candidate=item.candidate, ordinal=#full + 1} end
  table.sort(full, function(a,b)
    local x,y = a.candidate,b.candidate
    if x.start ~= y.start then return x.start < y.start end
    if x._end ~= y._end then return x._end > y._end end
    if x.quality ~= y.quality then return x.quality > y.quality end
    return a.ordinal < b.ordinal
  end)
  for _, item in ipairs(full) do yield(item.candidate) end
  while current do
    yield(current)
    current = iterator(iterator_state)
  end
end
return M
