-- One JP Kanji learning owner per context; q/v spellings share word families.
-- CN and legacy q counts are read-only bounded priors, never copied to this DB.
local family = require('jp_family')
local M = {}
local owners, serial, generation = {}, 0, 0

local function code(text) return family.resolve(text) .. ' ' end
local function clear_query(owner)
  owner.entries, owner.boosts, owner.scores = {}, {}, {}
  owner.query_generation = generation
end
local function lookup(owner, text)
  if owner.query_generation ~= generation then clear_query(owner) end
  local canonical, key = family.resolve(text), code(text)
  local cached = owner.entries[canonical]
  if cached ~= nil then return cached or nil end
  -- LookupWords tests the separator after the supplied input. The stored
  -- custom_code has a trailing space; the exact lookup argument must not.
  if owner.mem:user_lookup(canonical, false) then
    for entry in owner.mem:iter_user() do
      if entry.text == canonical and entry.custom_code == key then
        owner.entries[canonical] = entry
        return entry
      end
    end
  end
  owner.entries[canonical] = false
end

function M.acquire(engine)
  local ctx = engine.context
  local key = ctx:get_property('jp_memory_owner')
  local owner = owners[key]
  if not owner then
    serial = serial + 1
    key = tostring(serial)
    owner = {engine=engine, refs=0, priors={}, cache=nil}
    owner.mem = Memory(engine, engine.schema, 'jp_family')
    owner.mem:memorize(function(commit)
      local committed = commit:get()
      local records = require('jp_reading_metadata').selected(ctx, committed,
        owner.mem.lang_name, require('jp_v').navigation(ctx))
      for _, entry in ipairs(committed) do
        owner.mem:update_userdict(entry, 1, '')
      end
      for _, record in ipairs(records) do
        -- Static words already have a native reverse index. Only a newly
        -- composed surface needs a spelling record, with no selection count.
        if require('jp_query').lookup_codes(record.text) == '' then
          require('jp_reading_metadata').store(owner.mem, record, record.text)
        end
      end
      generation = generation + 1
      owner.cache = nil
      return true
    end)
    owner.update = ctx.update_notifier:connect(function()
      if owner.raw ~= ctx.input then
        owner.raw, owner.priors = ctx.input, {}
        clear_query(owner)
      end
    end)
    -- Native deletion acts on the canonical Phrase, hence resets the family.
    owner.deleted = ctx.delete_notifier:connect(function()
      generation = generation + 1
      owner.cache = nil
    end)
    owners[key] = owner
    ctx:set_property('jp_memory_owner', key)
    owner.key = key
  end
  owner.refs = owner.refs + 1
  return owner
end

function M.release(owner)
  if not owner then return end
  owner.refs = owner.refs - 1
  if owner.refs > 0 then return end
  owner.mem:finish_session()
  owner.mem:disconnect()
  owner.update:disconnect()
  owner.deleted:disconnect()
  owner.engine.context:set_property('jp_memory_owner', '')
  owners[owner.key] = nil
end

function M.begin_query(owner)
  owner.mem:finish_session()
  clear_query(owner)
end

function M.entry(owner, text)
  local entry = lookup(owner, text)
  if entry then return entry end
  entry = DictEntry()
  entry.text, entry.custom_code, entry.weight = family.resolve(text), code(text), 0
  return entry
end

function M.wrap(owner, original, text, comment, kind)
  local phrase = Phrase(owner.mem, kind or 'jp_family', original.start, original._end,
                        M.entry(owner, text))
  local shown = ShadowCandidate(phrase:toCandidate(), kind or original.type,
                               text, comment or original.comment)
  shown.preedit, shown.quality = original.preedit, original.quality
  -- The caller must retain original:spans() in its navigation registry. A new
  -- Memory Phrase cannot receive a native syllabifier through this Lua API.
  return shown
end

function M.learn(owner, text)
  if not family.is_han(text) and not require('jp_query').admitted(text) then return false end
  owner.mem:start_session()
  local result = owner.mem:update_userdict(M.entry(owner, text), 1, '')
  owner.mem:finish_session()
  generation = generation + 1
  owner.cache = nil
  return result
end

function M.reset(owner, text)
  local result = owner.mem:update_userdict(M.entry(owner, text), -1, '')
  owner.mem:finish_session()
  generation = generation + 1
  owner.cache = nil
  return result
end

function M.learned(owner)
  if not owner.cache or owner.generation ~= generation then
    owner.cache = {}
    owner.mem:finish_session()
    if owner.mem:user_lookup('', true) then
      for entry in owner.mem:iter_user() do
        if entry.commit_count > 0 and entry.custom_code == code(entry.text) then
          owner.cache[#owner.cache + 1] = entry
        end
      end
    end
    owner.generation = generation
    owner.reading_cache = {}
    for _, record in ipairs(require('jp_reading_metadata').list(owner.mem, owner.cache)) do
      local records = owner.reading_cache[record.text] or {}
      records[#records + 1] = record
      owner.reading_cache[record.text] = records
    end
  end
  return owner.cache
end

function M.readings(owner, text)
  M.learned(owner)
  return owner.reading_cache[family.resolve(text)] or {}
end

-- No second selection counter. Native commit_count is used for a smooth,
-- unbounded personal boost; the native recency probability breaks close ties.
function M.boost(owner, text)
  if owner.query_generation ~= generation then clear_query(owner) end
  local canonical = family.resolve(text)
  if owner.boosts[canonical] ~= nil then return owner.boosts[canonical] end
  local entry = lookup(owner, text)
  local boost = entry and entry.commit_count > 0
    and (math.log(1 + entry.commit_count) / 4 + math.exp(entry.weight)) or 0
  owner.boosts[canonical] = boost
  return boost
end

function M.observe_prior(owner, text, original, source)
  if source ~= 'chinese' and source ~= 'legacy_q' then return 0 end
  local phrase = original:get_genuine():to_phrase()
  local count = phrase and phrase.entry.commit_count or 0
  if count <= 0 then return 0 end
  local canonical = family.resolve(text)
  local log = math.log(1 + count)
  local prior = 0.2 * log / (1 + log)
  -- Alternate CN spellings / q readings are not independent observations.
  local previous = owner.priors[canonical] or 0
  owner.priors[canonical] = math.max(previous, prior)
  if owner.priors[canonical] ~= previous and owner.scores then owner.scores[canonical] = nil end
  return owner.priors[canonical]
end

function M.prior(owner, text) return owner.priors[family.resolve(text)] or 0 end
function M.score(owner, text)
  if owner.query_generation ~= generation then clear_query(owner) end
  local canonical = family.resolve(text)
  if owner.scores[canonical] == nil then
    owner.scores[canonical] = M.boost(owner, text) + M.prior(owner, text)
  end
  return owner.scores[canonical]
end
return M
