-- Shared component assembly. Native entrypoint names retain their tested interfaces.
probe_global_mode = require('shared.pc_probe_global_mode')
draft_limit = require('shared.draft_limit')
cn_translator = require('cn.cn_translator')
cn_exact_processor = require('cn.cn_exact_processor')
cn_exact_segmentor = cn_exact_processor.segmentor
en_processor = require('en.en_processor')
en_segmentor = require('en.en_segmentor')
u_translator = require('tools.u_translator')

research_mode_filter = require('ui.research_mode_filter')

candidate_comment_filter = require('ui.candidate_comment_filter')

tool_processor = require('tools.tool_processor')
tool_segmentor = require('tools.tool_segmentor')
tool_translator = require('tools.tool_translator')
select_hanzi = require('ui.select_hanzi')

candidate_keys = require('ui.candidate_keys')

-- Confirmed Japanese-v lookup and query information export.
query_info_submit = require('tools.query_info_submit')
jp_v = require('jp.jp_v')
jp_v_processor = jp_v.processor
jp_v_segmentor = jp_v.segmentor
jp_v_translator = jp_v.translator
jp_v_filter = jp_v.filter

jp_query = require('jp.jp_query')
jp_query_processor = jp_query.processor
jp_query_segmentor = jp_query.segmentor
jp_query_translator = jp_query.translator
jp_query_filter = jp_query.filter

-- Isolated exact whole-draft Japanese symbol names.
jp_named_symbols = require('jp.jp_named_symbols')

official_translator = require('shared.on_demand_translator')
