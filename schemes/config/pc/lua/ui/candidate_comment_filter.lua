-- SPDX-License-Identifier: GPL-3.0-only
-- Match the existing Chinese-horizontal / smart-English-vertical layouts.
local comment_labels = {
  ['完整词'] = '整', ['原文'] = '原', ['纠错'] = '糾', ['补全'] = '補',
  ['笔画'] = '筆', ['拆字'] = '拆', ['简拼'] = '略',
}
local greek_lookalikes = {
  ['Α']=true, ['Β']=true, ['Ε']=true, ['Ζ']=true, ['Η']=true,
  ['Ι']=true, ['Κ']=true, ['Μ']=true, ['Ν']=true, ['Ο']=true,
  ['Ρ']=true, ['Τ']=true, ['Υ']=true, ['Χ']=true, ['ο']=true,
}
return function(input, env)
  local english = env.engine.context:get_option('research_english')
  local seen={}
  for candidate in input:iter() do
    local comment = candidate.comment
    if greek_lookalikes[candidate.text] then
      comment = comment == '' and '希臘' or ('希臘 · ' .. comment)
    end
    if comment ~= '' then
      comment = comment:gsub('%S+', comment_labels)
      comment = english and (' | ' .. comment) or (' (' .. comment .. ')')
    end
    local genuine = candidate
    while genuine:get_dynamic_type() == 'Shadow' or genuine:get_dynamic_type() == 'Uniquified' do
      genuine = genuine:get_genuine()
    end
    local shown_type = candidate.type == 'mdx_sc_original' and genuine.type or candidate.type
    local shown = ShadowCandidate(genuine, shown_type, candidate.text, comment)
    shown.start, shown._end, shown.quality = candidate.start, candidate._end, candidate.quality
    local cp=#candidate.text>0 and utf8.codepoint(candidate.text)
    local hanzi=cp and ((cp>=0x3400 and cp<=0x9fff) or (cp>=0xf900 and cp<=0xfaff)
      or (cp>=0x20000 and cp<=0x3347f))
    local key=hanzi and (candidate.text..'\t'..candidate.start..':'..candidate._end)
    if not key or not seen[key] then
      if key then seen[key]=true end
      yield(shown)
    end
  end
end
