-- Inline Lua fixture (original test fixture for Deskset).
unit = 'metric'
calls = 0

local function counted(f)
  return function(...)
    calls = calls + 1
    return f(...)
  end
end

Convert = counted(function(celsius, scale)
  if scale == 'C' then return string.format('%.1f F', celsius * 9 / 5 + 32) end
  return string.format('%.1f C', (celsius - 32) * 5 / 9)
end)

Letter = counted(function(word, index) return word:sub(index, index) end)

Describe = counted(function(a, b, c, d)
  return table.concat({ type(a) .. ' ' .. tostring(a), type(b) .. ' ' .. tostring(b), tostring(c), tostring(d) }, ', ')
end)

Shout = counted(function(text) return text:upper() .. '!' end)

Welcome = counted(function(city) return 'Hi ' .. city end)

IsWarm = counted(function(celsius) return celsius > 20 end)

function Width(n) return n * 20 end
