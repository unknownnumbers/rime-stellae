-- SPDX-License-Identifier: GPL-3.0-only
local index = require('en_index')
local format = require('en_dlc_format')
local M = {}
local ids = {'math', 'physics', 'computer'}
local cached
local function identity(record) return record.code .. '\t' .. record.word end

local function read(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local bytes = file:read('*a')
  file:close()
  return bytes
end

local function english_records(directory, id)
  local manifest = read(directory .. '/manifest.tsv')
  if not manifest then return nil end
  manifest = '\n' .. manifest
  local revision = manifest:match('\nformat\t([^\r\n]+)')
  local module = manifest:match('\nid\t([^\r\n]+)')
  local languages = manifest:match('\nlanguages\t([^\r\n]+)')
  if revision ~= '1' or module ~= id or (languages ~= 'cn,en' and languages ~= 'en') then return nil end
  return format.parse(read(directory .. '/english.tsv'))
end

local function read_index(directory, records)
  local ok, prepared = pcall(index.load, directory .. '/english_index')
  if not ok then return nil end
  local aliases, count = {}, 0
  for _, record in ipairs(records) do
    if not aliases[record.alias] then
      aliases[record.alias], count = true, count + 1
    end
  end
  if #prepared.words ~= count then return nil end
  for _, word in ipairs(prepared.words) do
    if not aliases[word] then return nil end
    aliases[word] = nil
  end
  return prepared
end

local function suggest(indexes, query, budget)
  local matches, seen = {}, {}
  for _, prepared in ipairs(indexes) do
    for _, match in ipairs(prepared:suggest(query, budget)) do
      if not seen[match.word] then
        seen[match.word] = true
        matches[#matches + 1] = match
      end
    end
  end
  table.sort(matches, function(a, b)
    if a.edit ~= b.edit then return a.edit < b.edit end
    return a.word < b.word
  end)
  return matches
end

function M.load(vocab, extensions)
  local root = rime_api.get_user_data_dir() .. '/rymcp_dlc/'
  if cached and cached.root == root and cached.vocab == vocab and cached.extensions == extensions then
    return cached.value
  end
  local aliases, words, owners, ordinary, base = {}, {}, {}, {}, {}
  local indexes = {}
  for _, alias in ipairs(extensions.words) do
    for _, record in ipairs(extensions.aliases[alias]) do
      local key = identity(record)
      if not base[key] then base[key] = record end
    end
  end
  -- Package order is fixed by the package loader. The first definition owns
  -- a shared identity; additional aliases never add corpus counts.
  for _, id in ipairs(ids) do
    local directory = root .. id
    local records = english_records(directory, id)
    if records then
      local prepared = read_index(directory, records)
      if prepared then
        indexes[#indexes + 1] = prepared
      else
        log.warning('Install the prebuilt English correction index for the ' .. id .. ' DLC.')
      end
      for _, record in ipairs(records) do
        record.optional = true
        local key = identity(record)
        local owner = owners[key]
        if not owner then
          local original = base[key]
          if vocab.frequency[record.word] and record.code == record.word then
            owner = {code=record.code, word=record.word, shown=extensions.display[record.word],
              frequency=vocab.frequency[record.word], expansion=0}
          else
            owner = original or record
          end
          owners[key] = owner
        end
        if not aliases[record.alias] then aliases[record.alias] = {}; words[#words + 1] = record.alias end
        local group = aliases[record.alias]
        local duplicate = false
        for _, prior in ipairs(group) do if identity(prior) == key then duplicate = true; break end end
        if not duplicate then
          group[#group + 1] = {code=owner.code, word=owner.word, shown=owner.shown,
            frequency=owner.frequency, expansion=record.expansion, parent=record.parent,
            optional=owner.optional}
        end
        if not base[key] and not vocab.frequency[record.word] and owner.ordinary then
          ordinary[record.word] = true
        end
      end
    end
  end
  table.sort(words)
  local correction = {suggest=function(_, query, budget) return suggest(indexes, query, budget) end}
  local result = {aliases=aliases, words=words, ordinary=ordinary, index=correction}
  cached = {root=root, vocab=vocab, extensions=extensions, value=result}
  return result
end

return M
