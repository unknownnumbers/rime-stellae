-- Math vocabulary follows Ice calc_translator.lua (ChaosAlphard / DeepChirp).
-- Local parser: explicit arithmetic preserves NaN and detects intermediate overflow.
-- No Lua evaluation; the only callable functions are the mathematical ones below.
local M = {}
local NAN = 0 / 0
local function fail(kind) error(kind, 0) end
local function finite(x)
  if x == math.huge or x == -math.huge then fail('overflow') end
  return x
end
local function numeric(x)
  if type(x) ~= 'number' then fail('evaluation') end
  return x
end
local function binary(op, a, b)
  numeric(a); numeric(b)
  if a ~= a or b ~= b then return NAN end
  if op == '+' then return finite(a + b)
  elseif op == '-' then return finite(a - b)
  elseif op == '*' then return finite(a * b)
  elseif op == '/' then return b == 0 and NAN or finite(a / b)
  elseif op == '^' then
    if a == 0 and b < 0 then return NAN end
    return finite(a ^ b)
  end
end

-- Preserve explicit multiples of pi through ordinary scalar arithmetic.
-- Numeric closeness to pi (or to zero) alone is not evidence of an exact angle.
local function angle_after(op, a, b, pa, pb, value)
  if value == 0 then return 0 end
  if op == '+' and pa and pb then return pa + pb end
  if op == '-' and pa and pb then return pa - pb end
  if op == '*' then
    if pa and not pb then return pa * b end
    if pb and not pa then return a * pb end
  end
  if op == '/' and pa and not pb and b ~= 0 then return pa / b end
  if op == '^' and b == 1 then return pa end
end

local function exact_trig(name, multiple)
  if multiple == nil then return end
  local quarter = 2 * multiple
  -- Outside the safe integer range, float parity is not reliable.
  if math.abs(quarter) > 9007199254740991 or quarter ~= math.floor(quarter) then return end
  local phase = quarter % 4
  if name == 'sin' then return ({0, 1, 0, -1})[phase + 1] end
  if name == 'cos' then return ({1, 0, -1, 0})[phase + 1] end
  if name == 'tan' then return phase % 2 == 0 and 0 or NAN end
end

function M.format(x)
  if type(x) == 'string' then return x end
  if x ~= x then return 'NaN' end
  if x == 0 then return '0' end
  if x == math.floor(x) then return string.format('%.0f', x) end
  return string.format('%.14g', x)
end

local function factorial(x)
  if x < 0 or x ~= math.floor(x) then return NAN end
  -- 171! exceeds binary64; avoid looping through an unbounded integer input.
  if x > 170 then fail('overflow') end
  local result = 1.0
  for i = 2, x do result = result * i end
  return result
end

-- Integer functions use exact Lua integers internally, within binary64's
-- consecutive-integer range. Return floats to preserve the parser's arithmetic.
local MAX_EXACT_INTEGER = 9007199254740991
local function exact_integer(x, nonnegative)
  if x ~= math.floor(x) or (nonnegative and x < 0) then return nil end
  if math.abs(x) > MAX_EXACT_INTEGER then fail('overflow') end
  return math.floor(x)
end

local function integer_gcd(a, b)
  while b ~= 0 do a, b = b, a % b end
  return a
end

local function exact_product(a, b)
  if a > MAX_EXACT_INTEGER // b then fail('overflow') end
  return a * b
end

local function gcd(...)
  local result = 0
  for _, x in ipairs({...}) do
    local n = exact_integer(x)
    if not n then return NAN end
    result = integer_gcd(result, math.abs(n))
  end
  return result + 0.0
end

local function lcm(...)
  local values, has_zero = {}, false
  for _, x in ipairs({...}) do
    local n = exact_integer(x)
    if not n then return NAN end
    values[#values + 1] = math.abs(n)
    has_zero = has_zero or n == 0
  end
  -- A later zero makes the result zero even if earlier factors have a large LCM.
  if has_zero then return 0.0 end
  local result = 1
  for _, n in ipairs(values) do
    result = exact_product(result // integer_gcd(result, n), n)
  end
  return result + 0.0
end

local function count_selections(n, k, combination)
  n = exact_integer(n, true)
  if not n then return NAN end
  k = exact_integer(k, true)
  if not k then return NAN end
  if k > n then return 0.0 end
  local result = 1
  if combination then
    k = math.min(k, n - k)
    for i = 1, k do
      local numerator = n - k + i
      local divisor = integer_gcd(numerator, i)
      numerator = numerator // divisor
      local denominator = i // divisor
      -- Coprime to numerator, the remaining denominator divides result exactly.
      result = exact_product(result // denominator, numerator)
    end
  else
    for i = 0, k - 1 do result = exact_product(result, n - i) end
  end
  return result + 0.0
end

local functions = {}
local function register(name, minimum, maximum, fn)
  functions[name] = {minimum, maximum, fn}
end
register('floor', 1, 1, function(x) return math.floor(x) + 0.0 end)
register('ceil', 1, 1, function(x) return math.ceil(x) + 0.0 end)
register('round', 1, 1, function(x)
  local magnitude = math.abs(x)
  local whole = math.floor(magnitude)
  -- Compare the fractional part; adding 0.5 first can change a large integer.
  local rounded = whole + (magnitude - whole >= 0.5 and 1 or 0)
  return (x < 0 and -rounded or rounded) + 0.0
end)
register('gcd', 2, math.huge, gcd)
register('lcm', 2, math.huge, lcm)
register('perm', 2, 2, function(n, k) return count_selections(n, k, false) end)
register('comb', 2, 2, function(n, k) return count_selections(n, k, true) end)
for _, name in ipairs({'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'sqrt', 'exp', 'rad', 'deg'}) do
  register(name, 1, 1, math[name])
end
functions.arcsin = functions.asin
functions.arccos = functions.acos
functions.arctan = functions.atan
register('atan2', 2, 2, function(y, x) return math.atan(y, x) end)
register('sinh', 1, 1, function(x)
  local a = math.abs(x)
  if a < 0.5 then
    -- Avoid cancellation between exp(x) and exp(-x) near zero.
    local sum, term, n = x, x, 1
    repeat
      term = term * x * x / ((n + 1) * (n + 2))
      local next_sum = sum + term
      if next_sum == sum then return sum end
      sum, n = next_sum, n + 2
    until false
  end
  local v = math.exp(a - math.log(2)) - math.exp(-a) / 2
  return x < 0 and -v or v
end)
register('cosh', 1, 1, function(x)
  local a = math.abs(x)
  return math.exp(a - math.log(2)) + math.exp(-a) / 2
end)
register('tanh', 1, 1, function(x)
  if math.abs(x) < 0.5 then return functions.sinh[3](x) / functions.cosh[3](x) end
  local t = math.exp(-2 * math.abs(x))
  local v = (1 - t) / (1 + t)
  return x < 0 and -v or v
end)
register('log', 1, 2, function(base, x)
  if x == nil then return base <= 0 and NAN or math.log(base, 10) end
  if base <= 0 or base == 1 or x <= 0 then return NAN end
  return math.log(x) / math.log(base)
end)
register('loge', 1, 1, function(x) return x <= 0 and NAN or math.log(x) end)
register('log10', 1, 1, function(x) return x <= 0 and NAN or math.log(x, 10) end)
functions.ln = functions.loge
functions.lg = functions.log10
register('mod', 2, 2, function(a, b) return b == 0 and NAN or a % b end)
register('fact', 1, 1, factorial)
register('min', 1, math.huge, math.min)
register('max', 1, math.huge, math.max)
register('avg', 1, math.huge, function(...)
  local a, n = {...}, select('#', ...)
  local mean = 0.0
  for _, x in ipairs(a) do mean = finite(mean + x / n) end
  return mean
end)
register('var', 1, math.huge, function(...)
  local a, n = {...}, select('#', ...)
  local mean = functions.avg[3](...)
  local sum = 0.0
  for _, x in ipairs(a) do sum = finite(sum + finite((x - mean) ^ 2) / n) end
  return sum
end)
register('stdev', 1, math.huge, function(...)
  return math.sqrt(functions.var[3](...))
end)
register('random', 0, 2, function(...)
  local a = {...}
  for _, x in ipairs(a) do
    if x ~= math.floor(x) then fail('evaluation') end
  end
  -- math.random(0) has a Lua-specific full-width integer meaning, not Ice's 1..m.
  if #a == 1 and a[1] < 1 then fail('evaluation') end
  if #a == 2 and a[1] > a[2] then fail('evaluation') end
  return math.random(...) + 0.0
end)
functions.rdm = functions.random
register('frexp', 1, 1, function(x)
  if x == 0 then return '0 * 2^0' end
  local exponent = math.floor(math.log(math.abs(x), 2)) + 1
  -- Split the scaling so 2^1024 itself need not be representable.
  local half = math.floor(exponent / 2)
  local mantissa = (x / 2 ^ half) / 2 ^ (exponent - half)
  if math.abs(mantissa) < 0.5 then mantissa = mantissa * 2; exponent = exponent - 1 end
  if math.abs(mantissa) >= 1 then mantissa = mantissa / 2; exponent = exponent + 1 end
  return M.format(mantissa) .. ' * 2^' .. exponent
end)
register('ldexp', 2, 2, function(x, exponent)
  if exponent ~= math.floor(exponent) then fail('evaluation') end
  if x == 0 then return 0 end
  if exponent > 2100 then fail('overflow') end
  if exponent < -2100 then return 0 end
  -- Apply in bounded pieces, allowing small x with a large positive exponent.
  while exponent > 1023 do x = finite(x * 2 ^ 1023); exponent = exponent - 1023 end
  while exponent < -1022 do x = x * 2 ^ -1022; exponent = exponent + 1022 end
  return finite(x * 2 ^ exponent)
end)

local function call(name, args, angles)
  local f = functions[name]
  if not f then fail('unknown') end
  if #args < f[1] or #args > f[2] then fail('evaluation') end
  for _, a in ipairs(args) do numeric(a); if a ~= a then return NAN end end
  local exact = exact_trig(name, angles[1])
  if exact ~= nil then return exact, exact == 0 and 0 or nil end
  local result = f[3](table.unpack(args))
  if type(result) == 'number' then finite(result) end
  return result, name == 'rad' and args[1] / 180 or (result == 0 and 0 or nil)
end

local function parse(source)
  local tokens, pos = {}, 1
  while pos <= #source do
    local rest = source:sub(pos)
    local token = rest:match('^%s+')
    if token then
      pos = pos + #token
    else
      token = rest:match('^%d+%.?%d*[eE][+-]?%d+') or rest:match('^%.%d+[eE][+-]?%d+')
          or rest:match('^%d+%.?%d*') or rest:match('^%.%d+')
      if token then tokens[#tokens + 1] = {number=finite(tonumber(token) + 0.0)}
      else
        token = rest:match('^[A-Za-z][A-Za-z0-9]*') or rest:match('^[()+*/^%%!,%-]')
        if not token then fail('syntax') end
        tokens[#tokens + 1] = token
      end
      pos = pos + #token
    end
  end
  local index, expression = 1
  local function take()
    local token = tokens[index]
    if not token then fail('incomplete') end
    index = index + 1
    return token
  end
  local function expect(wanted)
    if take() ~= wanted then fail('syntax') end
  end
  local precedence = {['+']=10, ['-']=10, ['*']=20, ['/']=20, ['^']=40}
  expression = function(minimum)
    local token = take()
    local left, angle
    if type(token) == 'table' then left = token.number; angle = left == 0 and 0 or nil
    elseif token == '+' or token == '-' then
      left, angle = expression(30)
      numeric(left)
      if token == '-' then left = -left; angle = angle and -angle end
    elseif token == '(' then left, angle = expression(0); expect(')')
    elseif token == 'pi' then left, angle = math.pi, 1
    elseif token == 'e' then left = math.exp(1)
    elseif token:match('^[A-Za-z]') then
      expect('(')
      local args, angles = {}, {}
      if tokens[index] ~= ')' then
        repeat
          local value, multiple = expression(0)
          args[#args + 1] = value
          angles[#args] = multiple
          if tokens[index] ~= ',' then break end
          index = index + 1
        until false
      end
      expect(')')
      left, angle = call(token, args, angles)
    else fail('syntax') end
    while true do
      local op = tokens[index]
      if (op == '%' or op == '!') and 50 >= minimum then
        index = index + 1
        numeric(left)
        if left == left then
          left = op == '%' and left / 100 or factorial(left)
          angle = op == '%' and angle and angle / 100 or nil
        end
      else
        local power = precedence[op]
        if not power or power < minimum then break end
        index = index + 1
        local right, right_angle = expression(op == '^' and power or power + 1)
        local value = binary(op, left, right)
        angle = angle_after(op, left, right, angle, right_angle, value)
        left = value
      end
    end
    return left, angle
  end
  local value = expression(0)
  if index <= #tokens then fail('syntax') end
  return value
end

function M.evaluate(source)
  local ok, value = pcall(parse, source)
  if ok then return {text=M.format(value)} end
  local hints = {overflow='超出計算範圍', incomplete='算式未完成',
      syntax='算式格式錯誤', unknown='未知函數', evaluation='無法計算'}
  return {error=tostring(value), hint=hints[value] or '無法計算'}
end

return M
