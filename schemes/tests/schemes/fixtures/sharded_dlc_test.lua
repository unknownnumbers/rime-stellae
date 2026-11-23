-- SPDX-License-Identifier: GPL-3.0-only
local M = {}

function M.init(env)
  if env.engine.context:get_property('sharded_dlc_result') ~= '' then return end
  local loader = require('rymcp_dlc')
  local root = rime_api.get_user_data_dir()
  local directory = root .. '/rymcp_dlc/poetry/'
  local names = {'words.dict.yaml'}
  for index = 0, 31 do names[#names + 1] = string.format('words_%02d.dict.yaml', index) end
  local original, checks = {}, {}
  local function read(path)
    local file = assert(io.open(path, 'rb'))
    local data = file:read('*a'); file:close(); return data
  end
  local function write(path, data)
    local file = assert(io.open(path, 'wb')); file:write(data); file:close()
  end
  for _, name in ipairs(names) do original[name] = read(directory .. name) end
  local manifest = read(directory .. 'manifest.tsv')
  local function check(name, passed)
    checks[#checks + 1] = {name, not not passed}
    if not passed then error('Fixed sharded catalog check failed: ' .. name) end
  end
  local function restore()
    for name, data in pairs(original) do write(directory .. name, data) end
    write(directory .. 'manifest.tsv', manifest)
  end
  local function rebuild_manifest()
    local value = 'format\t2\nid\tpoetry\nrevision\tfixture\nlanguages\tcn\ncn-layout\tshards\ncn-rows\t32\n'
    for _, name in ipairs(names) do
      local data = read(directory .. name)
      value = value .. 'file\t' .. name .. '\t' .. #data .. '\t' .. loader.adler32(data) .. '\n'
    end
    write(directory .. 'manifest.tsv', value)
  end
  local function rejected(name, mutate, update_checksums)
    restore(); mutate()
    if update_checksums then rebuild_manifest() end
    local ok, value = pcall(loader.read, 'poetry')
    check(name, not ok or value == nil)
  end
  local result = {Passed=false, Error=nil}
  local ok, failure = pcall(function()
    check('adler-empty', loader.adler32('') == '00000001')
    check('adler-ascii', loader.adler32('Wikipedia') == '11e60398')
    check('adler-digits', loader.adler32('123456789') == '091e01de')
    local valid = loader.read('poetry')
    check('v2-thirty-two-packs', valid and #valid.packs == 32 and valid.cnrows == 32)
    local first, second = loader.modules(env.engine), loader.modules(env.engine)
    check('same-engine-construction-snapshot', first == second)
    local properties = {}
    local other = {context={
      get_property=function(_,name) return properties[name] or '' end,
      set_property=function(_,name,value) properties[name]=value end,
    }}
    check('same-runtime-shares-validated-metadata', loader.modules(other) == first)
    check('direct-read-remains-independent', loader.read('poetry') ~= valid)
    rejected('missing-piece', function() assert(os.remove(directory .. names[18])) end)
    check('cached-engine-detects-piece-deletion', #loader.modules(env.engine) == 0)
    restore()
    check('recovered-engine-snapshot', #loader.modules(env.engine) == 1)
    rejected('wrong-checksum', function() write(directory .. names[4], original[names[4]] .. '# changed\n') end)
    rejected('wrong-row-count', function() write(directory .. 'manifest.tsv', manifest:gsub('cn%-rows\t32', 'cn-rows\t33')) end)
    rejected('wrong-layout', function() write(directory .. 'manifest.tsv', manifest:gsub('cn%-layout\tshards', 'cn-layout\tunknown')) end)
    rejected('wrong-format', function() write(directory .. 'manifest.tsv', manifest:gsub('format\t2', 'format\t3')) end)
    rejected('v2-rejects-english-language', function() write(directory .. 'manifest.tsv', manifest:gsub('languages\tcn\n', 'languages\tcn,en\n')) end)
    rejected('master-must-not-duplicate-data', function() write(directory .. names[1], original[names[1]] .. 'Extra\ta a\t100\n') end, true)
    rejected('bad-required-include', function() write(directory .. names[3], original[names[3]]:gsub('words_02.dict', 'words_09.dict')) end, true)
    rejected('bad-final-pack-list', function() write(directory .. names[33], original[names[33]]:gsub('rymcp_dlc_poetry_17', 'rymcp_dlc_poetry_31')) end, true)
    rejected('wrong-dictionary-name', function() write(directory .. names[7], original[names[7]]:gsub('words_05', 'wrong_05')) end, true)
    rejected('wrong-dictionary-version', function() write(directory .. names[7], original[names[7]]:gsub("version: 'fixture'", "version: 'other'")) end, true)
    rejected('non-native-header-transform', function() write(directory .. names[7], original[names[7]]:gsub('%.%.%.\n', 'columns: [text, code]\n...\n')) end, true)
    rejected('piece-patch-rejected', function() write(directory .. names[7], original[names[7]]:gsub('%.%.%.\n', 'patch: {}\n...\n')) end, true)
    rejected('missing-trailing-newline', function() local data=original[names[5]]; write(directory .. names[5], data:sub(1,-2)) end, true)
    rejected('invalid-weight', function() write(directory .. names[5], original[names[5]]:gsub('\t100\n', '\tnan\n')) end, true)
    rejected('nonpositive-weight', function() write(directory .. names[5], original[names[5]]:gsub('\t100\n', '\t0\n')) end, true)
    rejected('invalid-code', function() write(directory .. names[5], original[names[5]]:gsub('\ta a a\t', '\ta  a\t')) end, true)
    rejected('duplicate-within-piece', function()
      local row=original[names[5]]:match('%.%.%.\n(.+)')
      write(directory .. names[5], original[names[5]] .. row)
    end, true)
    rejected('duplicate-between-pieces', function()
      local row=original[names[5]]:match('%.%.%.\n(.+)')
      write(directory .. names[6], original[names[6]]:gsub('(%.%.%.\n).*', '%1' .. row))
    end, true)
    rejected('global-order-required', function()
      local row_a=original[names[5]]:match('%.%.%.\n(.+)')
      local row_b=original[names[6]]:match('%.%.%.\n(.+)')
      write(directory .. names[5], original[names[5]]:gsub('(%.%.%.\n).*', '%1' .. row_b))
      write(directory .. names[6], original[names[6]]:gsub('(%.%.%.\n).*', '%1' .. row_a))
    end, true)
    rejected('empty-piece-rejected', function() write(directory .. names[5], original[names[5]]:gsub('(%.%.%.\n).*', '%1')) end, true)
    restore()
    assert(os.remove(directory .. 'manifest.tsv'))
    check('cached-engine-detects-uninstall', #loader.modules(env.engine) == 0)
    restore()
    check('same-engine-detects-reinstall', #loader.modules(env.engine) == 1)
    -- A larger fixed catalog exercises the streaming memory bound. The input
    -- is generated by this suite, with no real input or learning records.
    local function copy(from, to)
      local src=assert(io.open(from,'rb'));local dst=assert(io.open(to,'wb'))
      while true do local chunk=src:read(65536);if not chunk then break end;dst:write(chunk) end
      src:close();dst:close()
    end
    for _, name in ipairs(names) do copy(root .. '/stress/' .. name, directory .. name) end
    copy(root .. '/stress/manifest.tsv', directory .. 'manifest.tsv')
    collectgarbage('collect')
    local before, peak = collectgarbage('count'), collectgarbage('count')
    local started = os.clock()
    debug.sethook(function() peak=math.max(peak,collectgarbage('count')) end, '', 20000)
    local stress_ok, snapshot = pcall(loader.modules, env.engine)
    debug.sethook()
    result.StreamSeconds=os.clock()-started;result.LuaPeakDeltaKiB=peak-before
    local stress = stress_ok and snapshot[1]
    local rows=tonumber(read(root .. '/stress-rows.txt'))
    check('stress-complete-catalog', stress and stress.cnrows == rows and #stress.packs == 32)
    check('streaming-lua-memory-bound', result.LuaPeakDeltaKiB < 16384)
    local warm_started=os.clock()
    check('warm-engine-reuses-current-catalog', loader.modules(other) == snapshot)
    result.WarmSnapshotSeconds=os.clock()-warm_started
    result.StressRows=rows
    result.Passed=true
  end)
  debug.sethook()
  if not ok then result.Error=tostring(failure) end
  local parts={}
  for _, row in ipairs(checks) do parts[#parts+1]='{"Id":"'..row[1]..'","Passed":'..tostring(row[2])..'}' end
  local report='{"Passed":'..tostring(result.Passed)..',"Completed":'..tostring(result.Passed)
    ..',"Checks":['..table.concat(parts,',')..'],"StressRows":'..tostring(result.StressRows or 0)
    ..',"StreamSeconds":'..tostring(result.StreamSeconds or 0)..',"LuaPeakDeltaKiB":'..tostring(result.LuaPeakDeltaKiB or 0)
    ..',"WarmSnapshotSeconds":'..tostring(result.WarmSnapshotSeconds or 0)
    ..',"Error":'..(result.Error and string.format('%q',result.Error) or 'null')..'}'
  env.engine.context:set_property('sharded_dlc_result',report)
end

function M.func() return 2 end
return M
