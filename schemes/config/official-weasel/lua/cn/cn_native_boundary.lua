-- Validate a proposed end against the Phrase's retained native syllabifier.
-- This does not create a Candidate, DictEntry, Memory, or learning record.
local M = {}

function M.try(candidate, ending, syllable_count)
  local original_end = candidate._end
  candidate._end = ending
  local vertices = candidate:spans().vertices
  if #vertices ~= syllable_count + 1 or vertices[1] ~= candidate.start
      or vertices[#vertices] ~= ending then
    candidate._end = original_end
    return false
  end
  for index = 2, #vertices do
    if vertices[index] <= vertices[index - 1] then
      candidate._end = original_end
      return false
    end
  end
  return true, vertices
end

return M
