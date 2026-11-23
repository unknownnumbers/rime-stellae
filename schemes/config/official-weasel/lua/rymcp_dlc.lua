-- SPDX-License-Identifier: GPL-3.0-only
-- Optional modules are read only from the user directory, as complete units.
local M = {}
local ids = {'math', 'physics', 'computer', 'poetry'}
local known = {}
for _, id in ipairs(ids) do known[id] = true end
local MAX_FILE = 32 * 1024 * 1024

local function read_file(path, limit)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local data = file:read(limit + 1)
  file:close()
  if not data or #data > limit then return nil end
  return data
end

local function adler_update(data, a, b)
  for offset = 1, #data, 5552 do
    local last, i = math.min(offset + 5551, #data), offset
    while i + 15 <= last do
      local c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11,c12,c13,c14,c15,c16 = data:byte(i, i + 15)
      a=a+c1; b=b+a; a=a+c2; b=b+a; a=a+c3; b=b+a; a=a+c4; b=b+a
      a=a+c5; b=b+a; a=a+c6; b=b+a; a=a+c7; b=b+a; a=a+c8; b=b+a
      a=a+c9; b=b+a; a=a+c10; b=b+a; a=a+c11; b=b+a; a=a+c12; b=b+a
      a=a+c13; b=b+a; a=a+c14; b=b+a; a=a+c15; b=b+a; a=a+c16; b=b+a
      i = i + 16
    end
    while i <= last do a = a + data:byte(i); b = b + a; i = i + 1 end
    a, b = a % 65521, b % 65521
  end
  return a, b
end

local function adler32(data)
  local a, b = adler_update(data, 1, 0)
  return string.format('%08x', b * 65536 + a)
end
M.adler32 = adler32

local function lines(data)
  return (data .. '\n'):gmatch('(.-)\n')
end

local function safe_relative(path)
  if not path:match('^[A-Za-z0-9_./%-]+$') or path:sub(1, 1) == '/'
      or path:sub(-1) == '/' or path:find('//', 1, true) then return false end
  for part in path:gmatch('[^/]+') do
    if part == '.' or part == '..' then return false end
  end
  return true
end

local function parse_manifest(data, id)
  if data:sub(-1) ~= '\n' then return nil end
  local metadata, entries = {}, {}
  for raw in lines(data) do
    local line = raw:gsub('\r$', '')
    if line ~= '' then
      local key, value = line:match('^([a-z][a-z%-]*)\t([^\t]+)$')
      if key and key ~= 'file' then
        if metadata[key] or (key ~= 'format' and key ~= 'id'
            and key ~= 'revision' and key ~= 'languages'
            and key ~= 'cn-layout' and key ~= 'cn-rows') then return nil end
        metadata[key] = value
      else
        local path, size, checksum = line:match('^file\t([^\t]+)\t(%d+)\t([0-9a-f]+)$')
        size = tonumber(size)
        if not path or not safe_relative(path) or entries[path] or path == 'manifest.tsv'
            or not size or size < 1 or size > MAX_FILE or #checksum ~= 8 then return nil end
        entries[path] = {size=size, checksum=checksum}
      end
    end
  end
  if (metadata.format ~= '1' and metadata.format ~= '2') or metadata.id ~= id or not metadata.revision
      or not metadata.revision:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') then return nil end
  local languages = {}
  if metadata.languages == 'cn' then languages.cn = true
  elseif metadata.languages == 'en' then languages.en = true
  elseif metadata.languages == 'cn,en' then languages.cn, languages.en = true, true
  else return nil end
  if (not not languages.cn) ~= (entries['words.dict.yaml'] ~= nil)
      or (not not languages.en) ~= (entries['english.tsv'] ~= nil) then return nil end
  if metadata.format == '2' then
    if id ~= 'poetry' or metadata.languages ~= 'cn' or metadata['cn-layout'] ~= 'shards'
        or not metadata['cn-rows'] or not metadata['cn-rows']:match('^[1-9][0-9]*$')
        or tonumber(metadata['cn-rows']) < 32 or tonumber(metadata['cn-rows']) > 20000000 then return nil end
  elseif metadata['cn-layout'] or metadata['cn-rows'] then return nil end
  return {id=id, format=metadata.format, revision=metadata.revision, languages=languages,
    entries=entries, cnrows=tonumber(metadata['cn-rows'])}
end

local function read_cn(data, path, module, leaf, needs_patch)
  local _, body_start = data:find('\n%.%.%.\r?\n')
  if not body_start or data:sub(-1) ~= '\n' then return false end
  local config = Config()
  if not config:load_from_file(path)
      or config:get_string('name') ~= 'rymcp_dlc/' .. module.id .. '/' .. leaf
      or config:get_string('version') ~= module.revision
      or config:get_string('sort') ~= 'by_weight'
      or config:get_bool('use_preset_vocabulary') ~= false
      or config:get_item('import_tables') or config:get_item('encoder')
      or config:get_item('columns') or config:get_item('vocabulary') then return false end
  if not needs_patch and config:get_item('patch') then return false end
  local seen, count = {}, 0
  for raw in lines(data:sub(body_start + 1)) do
    local line = raw:gsub('\r$', '')
    if line ~= '' and line:sub(1, 1) ~= '#' then
      local text, code, raw_weight = line:match('^([^\t]+)\t([^\t]+)\t([^\t]+)$')
      local weight = tonumber(raw_weight)
      if not text or not utf8.len(text) or text:find('[%z\1-\31\127]')
          or not code:match('^[a-z ]+$') or code:sub(1, 1) == ' '
          or code:sub(-1) == ' ' or code:find('  ', 1, true)
          or not weight or weight ~= weight or weight <= 0 or weight > 2147483647 then return false end
      local identity = text .. '\t' .. code
      if seen[identity] then return false end
      seen[identity], count = weight, count + 1
    end
  end
  if count == 0 then return false end
  return seen, count, config
end

local function validate_cn(contents, module)
  local original, original_count, config = read_cn(contents['words.dict.yaml'],
    module.files['words.dict.yaml'], module, 'words', true)
  if not original then return false end
  local patch = config:get_map('patch')
  if not patch or patch.size ~= 1 then return false end
  local item = patch:get('translator/packs/+')
  local list = item and item:get_list()
  local first = list and list:get_value_at(0)
  if list and list.size == 1 and first and first.value == 'rymcp_dlc_' .. module.id then
    module.packs = {first.value}
    return true
  end
  local include = patch:get_value('__include')
  if module.id ~= 'poetry' or not include
      or include.value ~= 'rymcp_dlc/poetry/words_00.dict:/activation' then return false end
  local combined, total, packs = {}, 0, {}
  for index = 0, 31 do
    local suffix = string.format('%02d', index)
    local name = 'rymcp_dlc_poetry_' .. suffix
    local relative = 'words_' .. suffix .. '.dict.yaml'
    if not contents[relative] then return false end
    local entries, count, piece_config = read_cn(contents[relative], module.files[relative],
      module, 'words_' .. suffix, false)
    if not entries then return false end
    local activation = piece_config:get_map('activation')
    if not activation or activation.size ~= 1 then return false end
    if index < 31 then
      local next_piece = activation:get_value('__include')
      local expected = string.format('rymcp_dlc/poetry/words_%02d.dict:/activation', index + 1)
      if not next_piece or next_piece.value ~= expected then return false end
    else
      local final_item = activation:get('translator/packs/+')
      local final_list = final_item and final_item:get_list()
      if not final_list or final_list.size ~= 32 then return false end
      for part = 0, 31 do
        local value = final_list:get_value_at(part)
        if not value or value.value ~= string.format('rymcp_dlc_poetry_%02d', part) then return false end
      end
    end
    for identity, weight in pairs(entries) do
      if combined[identity] or original[identity] ~= weight then return false end
      combined[identity] = weight
    end
    total, packs[#packs + 1] = total + count, name
  end
  if total ~= original_count then return false end
  module.packs = packs
  return true
end


-- Sharded catalogs are checked with bounded buffers. Chinese records remain
-- owned by native tables; Lua retains only the module's paths and pack names.
local function stream_integrity(path, expected)
  local file = io.open(path, 'rb')
  if not file then return false end
  local a, b, total = 1, 0, 0
  while true do
    local data = file:read(65536)
    if not data then break end
    total = total + #data
    if total > expected.size then file:close(); return false end
    a, b = adler_update(data, a, b)
  end
  file:close()
  return total == expected.size and string.format('%08x', b * 65536 + a) == expected.checksum
end

local function stream_header(path, module, leaf, needs_patch)
  local config = Config()
  if not config:load_from_file(path)
      or config:get_string('name') ~= 'rymcp_dlc/' .. module.id .. '/' .. leaf
      or config:get_string('version') ~= module.revision
      or config:get_string('sort') ~= 'by_weight'
      or config:get_bool('use_preset_vocabulary') ~= false
      or config:get_item('import_tables') or config:get_item('encoder')
      or config:get_item('columns') or config:get_item('vocabulary')
      or (not needs_patch and config:get_item('patch')) then return nil end
  return config
end

local function record_reader(path)
  local reader = {file=io.open(path, 'rb'), count=0, body=false}
  if reader.file then
    local size = reader.file:seek('end')
    if not size or size < 1 or not reader.file:seek('set', size - 1)
        or reader.file:read(1) ~= '\n' then reader.file:close(); reader.file = nil
    else reader.file:seek('set', 0) end
  end
  function reader:close()
    if self.file then self.file:close(); self.file = nil end
  end
  function reader:next()
    if not self.file then return false end
    while true do
      local raw = self.file:read('*l')
      if not raw then
        self:close()
        if not self.body then return false end
        return nil
      end
      if #raw > 65536 then self:close(); return false end
      local line = raw:byte(-1) == 13 and raw:sub(1, -2) or raw
      if not self.body then
        if line == '...' then self.body = true end
      elseif line ~= '' and line:sub(1, 1) ~= '#' then
        local text, code, raw_weight = line:match('^([^%z\1-\31\127]+)\t([a-z][a-z ]*)\t([^\t]+)$')
        local weight = tonumber(raw_weight)
        if not text or not utf8.len(text) or code:byte(-1) == 32 or code:find('  ', 1, true)
            or not weight or weight ~= weight or weight <= 0 or weight > 2147483647 then
          self:close(); return false
        end
        self.count = self.count + 1
        return line, code, text
      end
    end
  end
  return reader
end

local function validate_stream_cn(module)
  local path = module.files['words.dict.yaml']
  local config = stream_header(path, module, 'words', true)
  if not config then return false end
  local patch = config:get_map('patch')
  local include = patch and patch:get_value('__include')
  if not patch or patch.size ~= 1 or not include
      or include.value ~= 'rymcp_dlc/poetry/words_00.dict:/activation' then return false end
  -- The master is an activation header, not a second copy of all records.
  local master = record_reader(path)
  if master:next() ~= nil or master.count ~= 0 then master:close(); return false end
  for relative in pairs(module.files) do
    if relative:match('%.dict%.yaml$') and relative ~= 'words.dict.yaml' then
      local suffix = relative:match('^words_(%d%d)%.dict%.yaml$')
      if not suffix or tonumber(suffix) > 31 then return false end
    end
  end
  local packs, total, previous_code, previous_text = {}, 0, nil, nil
  for index = 0, 31 do
    local suffix = string.format('%02d', index)
    local relative = 'words_' .. suffix .. '.dict.yaml'
    if not module.files[relative] then return false end
    local piece_config = stream_header(module.files[relative], module, 'words_' .. suffix, false)
    if not piece_config then return false end
    local activation = piece_config:get_map('activation')
    if not activation or activation.size ~= 1 then return false end
    if index < 31 then
      local next_piece = activation:get_value('__include')
      local expected = string.format('rymcp_dlc/poetry/words_%02d.dict:/activation', index + 1)
      if not next_piece or next_piece.value ~= expected then return false end
    else
      local final_item = activation:get('translator/packs/+')
      local final_list = final_item and final_item:get_list()
      if not final_list or final_list.size ~= 32 then return false end
      for part = 0, 31 do
        local value = final_list:get_value_at(part)
        if not value or value.value ~= string.format('rymcp_dlc_poetry_%02d', part) then return false end
      end
    end
    local piece = record_reader(module.files[relative])
    while true do
      local row, code, text = piece:next()
      if row == false then piece:close(); return false end
      if not row then break end
      if previous_code and (code < previous_code or (code == previous_code and text <= previous_text)) then piece:close(); return false end
      previous_code, previous_text, total = code, text, total + 1
    end
    if piece.count < 1 then return false end
    packs[#packs + 1] = 'rymcp_dlc_poetry_' .. suffix
  end
  if total ~= module.cnrows then return false end
  module.packs = packs
  return true
end

function M.read(id)
  if not known[id] then return nil end
  local directory = rime_api.get_user_data_dir() .. '/rymcp_dlc/' .. id
  local manifest = read_file(directory .. '/manifest.tsv', 65536)
  local module = manifest and parse_manifest(manifest, id)
  if not module then return nil end
  module.directory, module.files, module.file_sizes = directory, {}, {}
  module.manifest = manifest
  local contents = {}
  for relative, entry in pairs(module.entries) do
    local path = directory .. '/' .. relative
    if module.format == '2' then
      if not stream_integrity(path, entry) then return nil end
      module.files[relative] = path
    else
      local data = read_file(path, MAX_FILE)
      if not data or #data ~= entry.size or adler32(data) ~= entry.checksum then return nil end
      module.files[relative], contents[relative] = path, data
    end
    module.file_sizes[relative] = entry.size
  end
  if module.languages.cn then
    local valid
    if module.format == '2' then valid = validate_stream_cn(module)
    else valid = validate_cn(contents, module) end
    if not valid then return nil end
  end
  if module.languages.en then
    local ok, format = pcall(require, 'en_dlc_format')
    if not ok then return nil end
    module.english = format.parse(contents['english.tsv'])
    if not module.english then return nil end
  end
  module.entries = nil
  return module
end

-- A redeploy creates a new Lua state and validates every byte again. Within
-- this state, engines may share the validated metadata while the installed
-- manifests and required file sizes are unchanged. Direct reads stay strict.
local snapshots = setmetatable({}, {__mode='v'})
local owner_serial = 0
local runtime_snapshot
local function snapshot_current(snapshot)
  local root = rime_api.get_user_data_dir() .. '/rymcp_dlc/'
  for _, id in ipairs(ids) do
    if read_file(root .. id .. '/manifest.tsv', 65536) ~= snapshot.manifests[id] then return false end
  end
  for _, module in ipairs(snapshot) do
    for relative, path in pairs(module.files) do
      local file = io.open(path, 'rb')
      if not file then return false end
      local size = file:seek('end')
      file:close()
      if size ~= module.file_sizes[relative] then return false end
    end
  end
  return true
end

function M.modules(engine)
  local context = engine and engine.context
  if context then
    local nonce = context:get_property('_rymcp_dlc_snapshot')
    local previous = nonce and snapshots[nonce]
    if previous and snapshot_current(previous) then return previous end
    if runtime_snapshot and snapshot_current(runtime_snapshot) then
      owner_serial = owner_serial + 1
      local nonce = tostring(owner_serial)
      context:set_property('_rymcp_dlc_snapshot', nonce)
      snapshots[nonce] = runtime_snapshot
      return runtime_snapshot
    end
  end
  local result, cacheable = {manifests={}}, true
  local root = rime_api.get_user_data_dir() .. '/rymcp_dlc/'
  for _, id in ipairs(ids) do
    local manifest = read_file(root .. id .. '/manifest.tsv', 65536)
    result.manifests[id] = manifest
    local ok, module = pcall(M.read, id)
    if ok and module then result[#result + 1] = module
    elseif manifest then cacheable = false end
  end
  if context and cacheable then
    owner_serial = owner_serial + 1
    local nonce = tostring(owner_serial)
    context:set_property('_rymcp_dlc_snapshot', nonce)
    snapshots[nonce] = result
    runtime_snapshot = result
  end
  return result
end

return M
