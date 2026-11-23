-- Research assertions for match boundaries, run in the actual bundled Lua VM.
local matcher = require('cn_match')
local forms = require('cn_forms')
local cases = {
  {"an", {"na"}, "an", nil},
  {"an", {"na"}, "anli", 2, 1},
  {"hsunhoa", {"shun", "hao"}, nil, 2, 2},
  {"hsnu", {"shun"}, nil, nil},
  {"hs'un", {"shun"}, nil, nil},
  {"hsun'hoa", {"shun", "hao"}, nil, 2, 2},
  {"yon'chu", {"yong", "chu"}, nil, 1, 0},
  {"y'o'chu", {"yong", "chu"}, nil, nil},
  {"yong'chu'", {"yong", "chu"}, nil, 0, 0},
  {"anli", {"an", "li"}, nil, 0, 0},
  {"anli", {"na", "li"}, nil, 2, 1},
  {"xing", {"xing"}, nil, 2, 1},
  {"xin", {"xing"}, nil, 0, 0},
  {"zheng", {"zheng"}, nil, 2, 1},
  {"zhen", {"zheng"}, nil, 0, 0},
}
for index, case in ipairs(cases) do
  local kind, edits = matcher.classify(case[1], case[2], forms, case[3])
  assert(kind == case[4] and (kind == nil or edits == case[5]),
         'Chinese match boundary case failed: ' .. index)
end
return #cases
