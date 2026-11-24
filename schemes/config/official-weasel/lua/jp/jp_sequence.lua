-- Lazy alternatives over exactly one native Sentence segmentation.
-- First yield is the native sentence. Later yields replace one component,
-- tail first; this intentionally does not enumerate Cartesian combinations.
local M = {}

-- native_query(spelling, part_segment) must return a native Translation.
-- Returns next() -> candidate, native_vertices, component DictEntry array.
-- The caller owns wrapping/learning, deduplication and merging with partials.
function M.iter(original, query, seg, native_query, observe)
  local sentence = original:get_genuine():to_sentence()
  if not sentence then return end
  local entries, lengths = sentence.entrys, sentence.word_lengths
  local vertices = original:spans().vertices
  local starts, cursor = {}, seg.start
  for index, length in ipairs(lengths) do
    starts[index], cursor = cursor, cursor + length
  end
  return coroutine.wrap(function()
    coroutine.yield(original, vertices, entries)
    for part = #entries, 1, -1 do
      local start, ending = starts[part], starts[part] + lengths[part]
      local part_seg = Segment(start, ending)
      part_seg.tags = Set({'abc'})
      local spelling = query:sub(start-seg.start+1, ending-seg.start)
      local translation = native_query(spelling, part_seg)
      if observe then observe('query', part) end
      if translation then
        for candidate in translation:iter() do
          if observe then observe('pull', part) end
          -- Native ScriptTranslation emits whole matches before partials.
          if candidate._end < ending then break end
          if candidate.type ~= 'sentence' and candidate._end == ending
              and candidate.text ~= entries[part].text then
            local texts, changed = {}, {}
            for index, entry in ipairs(entries) do
              texts[index] = index == part and candidate.text or entry.text
              changed[index] = index == part
                and candidate:get_genuine():to_phrase().entry or entry
            end
            local combined = Candidate('jp_q_sequence', original.start,
              original._end, table.concat(texts), '')
            combined.preedit, combined.quality = original.preedit, original.quality
            coroutine.yield(combined, vertices, changed)
          end
        end
      end
    end
  end)
end
return M
