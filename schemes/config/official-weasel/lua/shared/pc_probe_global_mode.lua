-- Same-process coordinator; no schema switching or persistent mode file.
local M = {}
local G = {next_id=0, records={}, values={research_english=false, simplification=true},
           busy=false, held_printable={}}

-- ToUnicodeEx may report '+' on keydown but '=' after Shift is released.
-- Pair the two ASCII symbols of the same QWERTY key, and letter case.
local shifted = [=[~!@#$%^&*()_+{}|:"<>?]=]
local unshifted = [=[`1234567890-=[]\;',./]=]
local base_key = {}
for i = 1, #shifted do base_key[shifted:byte(i)] = unshifted:byte(i) end
local function printable_key(code)
  if code < 0x20 or code > 0x7e then return nil end
  if code >= 0x41 and code <= 0x5a then return code + 0x20 end
  return base_key[code] or code
end

-- This property exists only during the current frontend process_key request.
-- Missing/legacy/invalid data cannot prove that a physically held key is up.
local function physical_shift(ctx, key)
  local encoded = ctx:get_property('weasel_shift_snapshot') or ''
  local digits, message, vkey, info = encoded:match('^v1:(%d+):(%d+):(%d+):(%d+)$')
  local flags = digits and tonumber(digits)
  if not flags or flags < 0 or flags > 31 or (flags & 1) == 0 then return nil end
  if #message > 10 or #vkey > 10 or #info > 10 then return nil end
  local mt, vk, ki = tonumber(message), tonumber(vkey), tonumber(info)
  if mt > 0xffffffff or ki > 0xffffffff or
      (vk ~= 0x10 and vk ~= 0xa0 and vk ~= 0xa1) then return nil end
  local left, right = (flags & 4) ~= 0, (flags & 8) ~= 0
  local own = key.keycode == 0xffe1 and left or key.keycode == 0xffe2 and right
  if own == key:release() or (key:release() and (flags & 16) ~= 0) then return nil end
  return {left=left, right=right, printable=(flags & 2) ~= 0,
          repeated=(flags & 16) ~= 0, id=message .. ':' .. vkey .. ':' .. info}
end

local function arm_shift_tap(key, env, physical)
  local pending = G.shift_tap
  local code = key.keycode
  local chord = (key.modifier & 0x4c) ~= 0

  if physical then
    local other = code == 0xffe1 and physical.right or code == 0xffe2 and physical.left
    chord = chord or physical.printable or other
    if pending and pending.key == code and
        (pending.id == physical.id or (physical.repeated and pending.owner == env)) then
      -- The same native message may reach both callbacks. It can cancel a
      -- pending tap, but cannot turn a chord into a new eligible tap.
      pending.blocked = pending.blocked or chord
      return
    end
    if physical.repeated then
      if pending then pending.blocked = true end
      return
    end
    -- A fresh native down can recover when a prior release was not delivered.
    env.legacy_shift_down = nil
    if not physical.printable then G.held_printable = {} end
    G.shift_tap = {owner=env, key=code, id=physical.id, blocked=chord}
    return
  end

  -- Legacy clients deliver ordinary key events without the optional facts.
  -- A second visible Shift side or context is enough to cancel a pending tap.
  local down = env.legacy_shift_down or {}
  env.legacy_shift_down = down
  if pending then
    pending.blocked = pending.blocked or pending.owner ~= env or pending.key ~= code
                      or pending.id ~= nil or chord
  else
    G.shift_tap = {owner=env, key=code,
                   blocked=chord or next(G.held_printable) ~= nil or
                           next(down) ~= nil}
  end
  down[code] = true
end

local function apply_page_size(record)
  if not record.chinese_page_size or not record.english_page_size then return end
  local size = record.context:get_option('research_english')
               and record.english_page_size or record.chinese_page_size
  record.schema.page_size = size
  if record.schema.page_size ~= size then
    error('Mode pagination requires the matching patched librime-lua build')
  end
end

local function sync(record)
  for name, value in pairs(G.values) do
    if record.context:get_option(name) ~= value then
      record.context:set_option(name, value)
    end
  end
  apply_page_size(record)
end

local function guarded(fn)
  G.busy = true
  local ok, error_message = pcall(fn)
  G.busy = false
  if not ok then error(error_message) end
end

local function arm(record)
  if record.armed then return end
  guarded(function() sync(record) end)
  record.armed = true
end

function M.init(env)
  G.next_id = G.next_id + 1
  local record = {id=G.next_id, context=env.engine.context, alive=true, armed=false}
  record.schema = env.engine.schema
  record.chinese_page_size = record.schema.config:get_int('menu/chinese_page_size')
  record.english_page_size = record.schema.config:get_int('menu/english_page_size')
  env.record = record
  G.records[record.id] = record
  env.connection = record.context.option_update_notifier:connect(function(context, name)
    if name == 'research_english' and record.alive then apply_page_size(record) end
    if name == 'probe_options_ready' and record.alive and not record.armed then
      arm(record)
      return
    end
    if G.busy or not record.alive or not record.armed or G.values[name] == nil then return end
    local value = context:get_option(name)
    if G.values[name] == value then return end
    G.values[name] = value
    guarded(function()
      for _, peer in pairs(G.records) do
        if peer.alive and peer.armed then sync(peer) end
      end
    end)
  end)
end

function M.fini(env)
  if G.shift_tap and G.shift_tap.owner == env then
    G.shift_tap = nil
  end
  local record = env.record
  if record then
    record.alive = false
    G.records[record.id] = nil
  end
  if env.connection then env.connection:disconnect() end
  env.connection, env.record = nil, nil
end

function M.func(key, env)
  arm(env.record)
  local ctx = env.record.context
  local shift = key.keycode == 0xffe1 or key.keycode == 0xffe2
  if not shift then
    if G.shift_tap then G.shift_tap.blocked = true end
    local code = printable_key(key.keycode)
    if code then
      if key:release() then G.held_printable[code] = nil
      elseif (key.modifier & 0x4c) == 0 then G.held_printable[code] = true end
    end
    return 2
  end

  local physical = physical_shift(ctx, key)
  if not key:release() then
    arm_shift_tap(key, env, physical)
    return 0
  end

  if env.legacy_shift_down then env.legacy_shift_down[key.keycode] = nil end
  local tap = G.shift_tap
  G.shift_tap = nil
  if not tap or tap.owner ~= env or tap.key ~= key.keycode or tap.blocked
      or (key.modifier & 0x4c) ~= 0 or (tap.id and not physical)
      or (physical and (physical.printable or physical.left or physical.right)) then
    return 0
  end
  if ctx:get_option('ascii_mode') then return 0 end
  ctx:set_option('research_english', not ctx:get_option('research_english'))
  return 1
end
return M
