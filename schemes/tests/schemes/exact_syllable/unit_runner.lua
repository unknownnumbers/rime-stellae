-- SPDX-License-Identifier: GPL-3.0-only
-- Isolated processor and matcher checks before synthetic native input.
local M = {}

local function matcher_checks()
  local exact = require('cn_exact_spelling')
  local matcher = require('cn_match')
  local forms = require('cn_forms')
  local checked = 0
  local function check(name, condition)
    assert(condition, name)
    checked = checked + 1
  end
  check('unmarked input has no lock plan', exact.parse('xiao') == nil)
  local plan = exact.parse('ni\'xiao"ma"')
  check('apostrophe bounds first lock', #plan.locks == 2
    and plan.locks[1].first == 4 and plan.locks[1].last == 7
    and plan.locks[1].closing == 8)
  check('quote bounds next lock', plan.locks[2].first == 9
    and plan.locks[2].last == 10 and plan.locks[2].closing == 11)
  local encoded = exact.encode('ni\'xiao"ma', string.upper)
  check('atom encoding keeps byte positions', encoded == 'NI\'@XIAoMA'
    and #encoded == #'ni\'xiao"ma')
  check('unmarked prefix remains free', exact.unmarked(plan, 1, 3)
    and not exact.unmarked(plan, 4, 7))
  check('complete locked syllable', matcher.classify('xiao"', {'xiao'}, forms) == 0)
  check('lock forbids splitting', matcher.classify('xiao"', {'xi', 'ao'}, forms) == nil)
  check('unmarked abbreviation is unchanged', matcher.classify('x', {'xiao'}, forms) == 1)
  check('lock rejects abbreviation', matcher.classify('x"', {'xiao'}, forms) == nil)
  check('unmarked correction is unchanged', matcher.classify('xioa', {'xiao'}, forms) == 2)
  check('lock rejects correction', matcher.classify('xioa"', {'xiao'}, forms) == nil)
  check('xin normalization retains both full paths',
    matcher.classify('xin"', {'xin'}, forms) == 0
    and matcher.classify('xin"', {'xing'}, forms) == 0)
  check('right unmarked correction remains available',
    matcher.classify('xiao"hoa', {'xiao', 'hao'}, forms) == 2)
  check('candidate truncated inside lock is rejected',
    matcher.classify('xi', {'xi'}, forms, 'xiao"', nil, 0,
      exact.parse('xiao"')) == nil)
  check('later candidate uses original base offset',
    matcher.classify('hao"', {'hao'}, forms, 'ni\'hao"', nil, 3,
      exact.parse('ni\'hao"')) == 0)
  local endings = matcher.prefix_ends('xiao"ma', {'xiao'}, forms)
  check('prefix DP consumes closing quote atomically',
    endings[5] and endings[5][1] == 0 and not endings[2])
  return checked
end

local function run_once(env)
  if env.unit_checks_done then return end
  env.unit_checks_done = true
  local saved = {draft_limit=package.loaded.draft_limit,
    Segment=_G.Segment, Set=_G.Set}
  local ok, result = pcall(function()
    local root = rime_api.get_user_data_dir() .. '/lua/'
    local processor_tests = assert(loadfile(root .. 'cn_exact_processor_unit.lua'))
    local count = processor_tests(root .. 'cn_exact_processor.lua')
    -- The matcher checks use real modules after synthetic API stubs are gone.
    package.loaded.draft_limit = saved.draft_limit
    _G.Segment, _G.Set = saved.Segment, saved.Set
    local matches = matcher_checks()
    return 'PASS processor=' .. count .. ' matcher=' .. matches
  end)
  package.loaded.draft_limit = saved.draft_limit
  _G.Segment, _G.Set = saved.Segment, saved.Set
  env.engine.context:set_property('cn_exact_unit_checks',
    ok and result or ('FAIL ' .. tostring(result)))
end

function M.init(env) run_once(env) end
function M.func(_, env)
  run_once(env)
  return 2
end

return M
