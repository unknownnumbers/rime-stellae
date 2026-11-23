-- SPDX-License-Identifier: GPL-3.0-only
-- Synthetic integration fixture only. F12 observes without changing selection.
local M = {}
local property = 'cn_exact_test_selection'
local function field(value)
  return tostring(value == nil and '' or value):gsub('[\t\r\n]', ' ')
end

function M.init(env)
  assert(env.engine.schema.config:get_bool('cn_decoder/enable_user_dict') == false, 'The synthetic observer needs a dictionary-only decoder')
  env.decoder = Memory(env.engine, env.engine.schema, 'cn_decoder')
end

function M.fini(env)
  env.decoder = nil
end

function M.func(key, env)
  if key:release() or key.modifier ~= 0 or key.keycode ~= 0xffc9 then return 2 end
  local ctx = env.engine.context
  local candidate = ctx:get_selected_candidate()
  if not candidate then ctx:set_property(property, ''); return 1 end
  local genuine = candidate
  while genuine:get_dynamic_type() == 'Shadow' or genuine:get_dynamic_type() == 'Uniquified' do
    genuine = genuine:get_genuine()
  end
  local phrase = genuine:to_phrase()
  local code = phrase and table.concat(env.decoder:decode(phrase.code), ' ') or ''
  local ok, vertices = pcall(function() return genuine:spans().vertices end)
  local values = {
    candidate.start, candidate._end, genuine.start, genuine._end,
    code, genuine.type, candidate.text,
    ok and table.concat(vertices, ',') or '',
    phrase and phrase.matching_code_size or '', genuine:get_dynamic_type(), candidate.preedit,
  }
  for index, value in ipairs(values) do values[index] = field(value) end
  ctx:set_property(property, table.concat(values, '\t'))
  return 1
end

return M
