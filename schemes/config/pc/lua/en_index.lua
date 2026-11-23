-- Binary prefix-delete recall, followed by the project's unrestricted DL.
local distance = require('pc_probe_greek_proxy').distance
local M, Index, cache = {}, {}, {}
Index.__index = Index
local PREFIX_LENGTH, KEY_WIDTH, RECORD_SIZE = 7, 8, 16

local function read_file(path)
  local file = assert(io.open(path, 'rb'))
  local bytes = file:read('*a')
  file:close()
  return bytes
end

local function deletion_keys(query, budget)
  local prefix = query:sub(1, PREFIX_LENGTH)
  local seen, frontier, count = {[prefix]=true}, {prefix}, 1
  for _ = 1, budget do
    local following = {}
    for _, value in ipairs(frontier) do
      for i = 1, #value do
        local key = value:sub(1, i - 1) .. value:sub(i + 1)
        if not seen[key] then
          seen[key], count = true, count + 1
          following[#following + 1] = key
        end
      end
    end
    frontier = following
  end
  return seen, count
end

local function lookup(index, key)
  local padded = key .. string.rep('\0', KEY_WIDTH - #key)
  local low, high = 1, index.key_count
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local start = (mid - 1) * RECORD_SIZE + 1
    local stored = index.keys:sub(start, start + KEY_WIDTH - 1)
    if stored == padded then
      return string.unpack('<I4I4', index.keys, start + KEY_WIDTH)
    elseif stored < padded then
      low = mid + 1
    else
      high = mid - 1
    end
  end
end

function M.load(directory)
  directory = directory:gsub('[\\/]+$', '')
  if cache[directory] then return cache[directory] end
  local words = {}
  for word in read_file(directory .. '/words.txt'):gmatch('[^\r\n]+') do
    words[#words + 1] = word
  end
  local keys = read_file(directory .. '/keys.bin')
  local postings = read_file(directory .. '/postings.bin')
  assert(#keys % RECORD_SIZE == 0 and #postings % 4 == 0, 'Invalid English index record size')
  local index = setmetatable({words=words, keys=keys, postings=postings,
                              key_count=#keys / RECORD_SIZE}, Index)
  cache[directory] = index
  return index
end

-- Optional catalogs keep their own word IDs and disappear with their schema
-- instance. They never enter the persistent base-index cache.
function M.from_words(words)
  local postings = {}
  for id, word in ipairs(words) do
    for key in pairs(deletion_keys(word, 2)) do
      local group = postings[key]
      if not group then group = {}; postings[key] = group end
      group[#group + 1] = id
    end
  end
  return setmetatable({words=words, memory_postings=postings}, Index)
end

function Index:suggest(query, budget)
  query = query:lower()
  local _, letters = query:gsub('[a-z]', '')
  local allowed = letters < 3 and 0 or (letters < 5 and 1 or 2)
  budget = math.max(0, math.min(budget or allowed, allowed, 2))
  local results = {}
  local stats = {budget=budget, delete_keys=0, candidates=0, distance_checks=0}
  if budget == 0 or not query:match("^[a-z][a-z'%-]*$") then return results, stats end

  local keys, count = deletion_keys(query, budget)
  stats.delete_keys = count
  local seen = {}
  for key in pairs(keys) do
    local group = self.memory_postings and self.memory_postings[key]
    local offset, length
    if not self.memory_postings then offset, length = lookup(self, key) end
    if group or offset then
      length = group and #group or length
      for i = 0, length - 1 do
        local word_id = group and group[i + 1] or string.unpack('<I4', self.postings, offset + i * 4 + 1)
        if not seen[word_id] then
          seen[word_id] = true
          stats.candidates = stats.candidates + 1
          local word = self.words[word_id]
          if math.abs(#query - #word) <= budget then
            stats.distance_checks = stats.distance_checks + 1
            local edits = distance(query, word)
            if edits > 0 and edits <= budget then
              results[#results + 1] = {word=word, edit=edits}
            end
          end
        end
      end
    end
  end
  table.sort(results, function(a, b)
    if a.edit ~= b.edit then return a.edit < b.edit end
    return a.word < b.word
  end)
  return results, stats
end

return M
