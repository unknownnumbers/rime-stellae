-- SPDX-License-Identifier: GPL-3.0-only
-- This template is executed only against one offline database clone.
local target, old_name, new_name = @DATABASE@, @OLD_NAME@, @NEW_NAME@
local rename = @RENAME@
local db = assert(LevelDb(target))
assert(db:open(), 'Cannot open the offline learning clone')
local identity = '\1/db_name'
local function rows()
  local result = {}
  for key, value in db:query(''):iter() do result[#result + 1] = {key, value} end
  -- Release the native iterator before closing its underlying database.
  collectgarbage('collect')
  return result
end
local before = rows()
local embedded = assert(db:fetch(identity), 'The learning clone has no identity')
assert(embedded == old_name or (not rename and embedded == new_name), 'Unexpected learning clone identity')
if rename then assert(db:update(identity, new_name)) end
local after = rows()
assert(#before == #after, 'Learning clone record count changed')
local count, metadata = 0, 0
local opaque = assert(io.open(@OPAQUE_FILE@, 'wb'))
for index, row in ipairs(before) do
  local other = after[index]
  assert(row[1] == other[1], 'Learning record key changed')
  if row[1] == identity and rename then
    assert(other[2] == new_name, 'Learning identity did not update')
  else
    assert(row[2] == other[2], 'Learning record value changed')
  end
  if row[1]:sub(1, 1) == '\1' then metadata = metadata + 1 else count = count + 1 end
  if row[1] ~= identity then
    opaque:write(string.pack('>I8', #row[1]), row[1], string.pack('>I8', #row[2]), row[2])
  end
end
assert(opaque:close())
local final_identity = assert(db:fetch(identity))
assert(db:close())
local report = assert(io.open(@REPORT_FILE@, 'wb'))
report:write(string.format(
  '{"passed":true,"records":%d,"metadataRecords":%d,"identityBefore":"%s","identityAfter":"%s","allOtherRawRecordsUnchanged":true}\n',
  count, metadata, embedded, final_identity))
assert(report:close())
