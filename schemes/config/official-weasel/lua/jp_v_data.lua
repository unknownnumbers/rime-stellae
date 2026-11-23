-- Sparse word metadata prototype. Content/API are identical to jp_v_data.
-- Licensing and source attribution: licenses/jp-v-sources.md.
local M = {}
local characters = require('jp_v_chars')
local index
local file
local cache = {}

-- Compare bytes explicitly: the generated index is UTF-8 byte ordered,
-- independent of the host's locale collation for Lua string comparison.
local function compare(a, b)
  local length = math.min(#a, #b)
  for i = 1, length do
    local aa, bb = a:byte(i), b:byte(i)
    if aa < bb then return -1 end
    if aa > bb then return 1 end
  end
  if #a < #b then return -1 end
  if #a > #b then return 1 end
  return 0
end

function M.get_character(character)
  return characters[character]
end

function M.get_word(text)
  local remembered = cache[text]
  if remembered ~= nil then return remembered or nil end
  if not index then index = require('jp_v_words_index') end
  local low, high, block = 1, #index.blocks, 0
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if compare(index.blocks[middle][1], text) <= 0 then
      block = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end
  if block == 0 then cache[text] = false; return nil end
  if not file then
    file = assert(io.open(require('scheme_data').path('jp_v_words.tsv'), 'rb'))
  end
  assert(file:seek('set', index.blocks[block][2]))
  for _ = 1, index.stride do
    local line = file:read('*l')
    if not line then break end
    local separator = line:find('\t', 1, true)
    local word = line:sub(1, separator - 1)
    local difference = compare(word, text)
    if difference == 0 then
      local readings = {}
      for reading in line:sub(separator + 1):gmatch('[^\t]+') do
        readings[#readings + 1] = reading
      end
      cache[text] = readings
      return readings
    end
    if difference > 0 then break end
  end
  cache[text] = false
  return nil
end

M.characters = characters
return M
