-- Dispatch tool input before starting a candidate query on stock librime-lua.
local chinese = require('cn_translator')
local lookup = require('u_translator')
local tools = require('tool_translator')
local M = {}

function M.init(env)
  env.chinese = {engine=env.engine}
  env.tools = {engine=env.engine}
  chinese.init(env.chinese)
  tools.init(env.tools)
end

function M.fini(env)
  if env.lookup then lookup.fini(env.lookup) end
  tools.fini(env.tools)
  chinese.fini(env.chinese)
end

function M.func(input, seg, env)
  if env.engine.context:get_option('research_english') then
    return chinese.func(input, seg, env.chinese)
  end
  if seg.start == 0 and (seg:has_tag('tool_calculator') or seg:has_tag('tool_unicode')) then
    return tools.func(input, seg, env.tools)
  end
  if seg.start == 0 and input:match("^uU[a-z]+U?'?$") then
    if not env.lookup then
      env.lookup = {engine=env.engine}
      lookup.init(env.lookup)
    end
    return lookup.func(input, seg, env.lookup)
  end
  return chinese.func(input, seg, env.chinese)
end

return M
