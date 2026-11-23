local M = {}
local exact = require('cn_exact_spelling')

local function advance(raw, first, length, kind, plan, base)
  if plan then
    local following = exact.advance(plan, first + (base or 0), length, kind)
    return following and following - (base or 0)
  end
  local following = first + length
  while raw:sub(following, following) == "'"
      or raw:sub(following, following) == ' ' do following = following + 1 end
  return following
end

local function form(spellings, extra, raw)
  local kind = spellings.values[raw]
  if kind then return kind, kind == 2 and 1 or 0 end
  local cost = extra and extra[raw]
  if cost then return 2, cost end
end

-- All input boundaries for the same decoded word. This does not
-- discard trailing input: the caller compares the continuation separately.
function M.prefix_ends(raw, syllables, forms, extras, plan, base)
  plan = plan or exact.parse(raw)
  local positions = {[0]={0, 0}}
  local _, letter_count = raw:gsub('[A-Za-z]', '')
  for _, syllable in ipairs(syllables) do
    local spellings, following = forms[syllable], {}
    local extra = extras and extras[syllable]
    if not spellings then return {} end
    for offset, matched in pairs(positions) do
      for length = 1, math.min(spellings.max_length, #raw - offset) do
        local form_kind, cost = form(spellings, extra, raw:sub(offset + 1, offset + length))
        if form_kind and (form_kind < 2 or letter_count >= 3) then
          local next_position = advance(raw, offset + 1, length, form_kind, plan, base)
          if next_position and next_position <= #raw + 1 then
          local stop = next_position - 1
          local kind = math.max(matched[1], form_kind)
          local edits = matched[2] + cost
          local previous = following[stop]
          if not previous or kind < previous[1]
              or (kind == previous[1] and edits < previous[2]) then
            following[stop] = {kind, edits}
          end
          end
        end
      end
    end
    positions = following
  end
  return positions
end

-- Match the candidate's real syllables, keeping separators as hard boundaries.
function M.classify(raw, decoded_syllables, forms, segment_input, extras, base, plan)
  plan = plan or exact.parse(segment_input or raw)
  if #decoded_syllables == 0 then return nil end
  for _, syllable in ipairs(decoded_syllables) do
    if not forms[syllable] then return nil end
  end

  -- A partial candidate may cover two letters inside a longer unconfirmed input.
  local _, letter_count = (segment_input or raw):gsub('[A-Za-z]', '')
  local memo = {}
  local function match(index, position)
    if index > #decoded_syllables then
      if position == #raw + 1 then return 0, 0 end
      return nil
    end
    memo[index] = memo[index] or {}
    local cached = memo[index][position]
    if cached ~= nil then
      if cached == false then return nil end
      return cached[1], cached[2]
    end

    local best_kind, best_edits
    local spellings = forms[decoded_syllables[index]]
    local extra = extras and extras[decoded_syllables[index]]
    for length = 1, math.min(spellings.max_length, #raw - position + 1) do
      local form_kind, cost = form(spellings, extra, raw:sub(position, position + length - 1))
      if form_kind and (form_kind ~= 2 or letter_count >= 3) then
        local next_position = advance(raw, position, length, form_kind, plan, base)
        local tail_kind, tail_edits
        if next_position then tail_kind, tail_edits = match(index + 1, next_position) end
        if tail_kind then
          local kind = math.max(form_kind, tail_kind)
          local edits = cost + tail_edits
          if best_kind == nil or kind < best_kind
              or (kind == best_kind and edits < best_edits) then
            best_kind, best_edits = kind, edits
          end
        end
      end
    end
    memo[index][position] = best_kind and {best_kind, best_edits} or false
    return best_kind, best_edits
  end
  return match(1, 1)
end

-- Complete syllable paths only: exact, one adjacent transposition, one enabled
-- neighbor substitution, or one enabled interior omission per syllable.
-- Prefix+extra-letter paths cannot establish a complete correction boundary.
local neighbor_keys = require('cn_neighbor_keys')

local function equal_length_edits(fragment, spelling, neighbor_enabled, transposition_enabled)
  if #fragment ~= #spelling then return nil end
  if fragment == spelling then return 0 end
  local first
  for offset = 1, #spelling do
    if fragment:sub(offset, offset) ~= spelling:sub(offset, offset) then
      first = offset
      break
    end
  end
  -- Both swapped letters must belong to this complete syllable; a separator
  -- cannot be swapped or crossed. Callers may exclude R04 from a trusted lane
  -- while retaining it for the existing boundary comparison.
  if transposition_enabled ~= false and first < #spelling
      and fragment:sub(first, first) == spelling:sub(first + 1, first + 1)
      and fragment:sub(first + 1, first + 1) == spelling:sub(first, first)
      and fragment:sub(first + 2) == spelling:sub(first + 2) then return 1 end
  if neighbor_enabled and #spelling >= 2
      and fragment:sub(first + 1) == spelling:sub(first + 1) then
    local adjacent = neighbor_keys[spelling:sub(first, first)]
    if adjacent and adjacent:find(fragment:sub(first, first), 1, true) then return 1 end
  end
end

function M.full_correction_ends(raw, decoded_syllables, full_spellings, neighbor_enabled, missing_enabled, transposition_enabled, plan, base)
  plan = plan or exact.parse(raw)
  if #decoded_syllables == 0 then return {} end
  local _, letter_count = raw:gsub('[A-Za-z]', '')
  if letter_count < 3 then return {} end
  -- Keep unchanged and corrected routes separately. An exact alternative at
  -- the same offset must not discard a genuine correction on another route.
  local positions = {[0] = {exact = true}}
  for _, syllable in ipairs(decoded_syllables) do
    local following = {}
    for offset, previous in pairs(positions) do
      local function extend(length, cost)
        local next_position = advance(raw, offset + 1, length, cost == 0 and 0 or 2, plan, base)
        if not next_position or next_position > #raw + 1 then return end
        local stop = next_position - 1
        local found = following[stop]
        if not found then found = {}; following[stop] = found end
        if cost == 0 and previous.exact then found.exact = true end
        local edits = previous.edits and previous.edits + cost
        if cost > 0 and previous.exact then edits = cost end
        if edits and (not found.edits or edits < found.edits) then found.edits = edits end
      end
      for _, spelling in ipairs(full_spellings[syllable] or {}) do
        local fragment = raw:sub(offset + 1, offset + #spelling)
        local cost = equal_length_edits(fragment, spelling, neighbor_enabled, transposition_enabled)
        if cost then extend(#spelling, cost) end
        if missing_enabled and #spelling >= 3 then
          local shorter = raw:sub(offset + 1, offset + #spelling - 1)
          if #shorter == #spelling - 1 then
            -- R06 keeps both ends of the complete spelling. A missing tail
            -- remains normal prefix matching rather than a full correction.
            for omitted = 2, #spelling - 1 do
              if shorter == spelling:sub(1, omitted - 1) .. spelling:sub(omitted + 1) then
                extend(#shorter, 1)
                break
              end
            end
          end
        end
      end
    end
    positions = following
  end
  local ends = {}
  for stop, matched in pairs(positions) do
    if matched.edits then ends[stop] = {edits = matched.edits} end
  end
  return ends
end

-- Boolean compatibility for callers checking the candidate's current range.
function M.full_spelling_correction(raw, decoded_syllables, full_spellings, neighbor_enabled, missing_enabled, transposition_enabled)
  return M.full_correction_ends(raw, decoded_syllables, full_spellings,
    neighbor_enabled, missing_enabled, transposition_enabled)[#raw] ~= nil
end

return M
