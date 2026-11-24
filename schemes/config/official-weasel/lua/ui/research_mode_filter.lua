-- SPDX-License-Identifier: GPL-3.0-only
return function(input, env)
  local english = env.engine.context:get_option('research_english')
  for candidate in input:iter() do
    if not english or candidate.type == 'research_english' then yield(candidate) end
  end
end
