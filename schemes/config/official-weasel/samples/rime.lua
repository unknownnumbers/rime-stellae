-- Daily integrated Luna scheme. Shared module names retain the tested interfaces.
probe_global_mode = require('pc_probe_global_mode')
draft_limit = require('draft_limit')
cn_translator = require('cn_translator')
cn_exact_processor = require('cn_exact_processor')
cn_exact_segmentor = cn_exact_processor.segmentor
en_processor = require('en_processor')
en_segmentor = require('en_segmentor')
u_translator = require('u_translator')

function research_mode_filter(input, env)
  local english = env.engine.context:get_option('research_english')
  for candidate in input:iter() do
    if not english or candidate.type == 'research_english' then yield(candidate) end
  end
end

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
function candidate_comment_filter(input, env)
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

tool_processor = require('tool_processor')
tool_segmentor = require('tool_segmentor')
tool_translator = require('tool_translator')
select_hanzi = require('select_hanzi')

candidate_keys = require('candidate_keys')

-- Confirmed Japanese-v lookup and query information export.
query_info_submit = require('query_info_submit')
jp_v = require('jp_v')
jp_v_processor = jp_v.processor
jp_v_segmentor = jp_v.segmentor
jp_v_translator = jp_v.translator
jp_v_filter = jp_v.filter

jp_query = require('jp_query')
jp_query_processor = jp_query.processor
jp_query_segmentor = jp_query.segmentor
jp_query_translator = jp_query.translator
jp_query_filter = jp_query.filter

-- Isolated exact whole-draft Japanese symbol names.
jp_named_symbols = require('jp_named_symbols')

official_translator = require('official_translator')
