-- Lua showcase (original test fixture for Deskset).
-- Global scope runs when the skin loads, so inline Lua can use these before Initialize().
libraryVersion = 'not loaded'
clicks = 0

function Initialize()
  dofile(SKIN:GetVariable('@') .. 'Scripts\\Library.lua')
  libraryVersion = Library.version

  -- Lay out the bars from the measure's own options.
  local count = SELF:GetNumberOption('Bars', 5)
  local colors = Library.split(SELF:GetOption('Palette'), '|')
  for i = 1, count do
    local bar = SKIN:GetMeter('Bar' .. i)
    if bar then
      bar:SetX(16 + (i - 1) * 39)
      bar:SetW(32)
      SKIN:Bang('!SetOption', 'Bar' .. i, 'SolidColor', colors[i] or '255,255,255')
    end
  end

  -- Read a data file through a Windows-style path relative to the skin folder.
  local tips = {}
  for line in io.lines(SKIN:MakePathAbsolute('@Resources\\Data\\tips.txt')) do
    if line ~= '' then tips[#tips + 1] = line end
  end
  SKIN:Bang('!SetVariable', 'Tip', tips[1] or 'no tips found')
end

function Update()
  local seconds = SKIN:GetMeasure('MeasureSeconds'):GetValue()
  local load = 12.5 + (seconds % 10) * 8
  -- Bar heights follow a small wave; the bars sit on a baseline at y = 142.
  for i = 1, SELF:GetNumberOption('Bars', 5) do
    local h = 8 + ((i * 7 + seconds) % 5) * 10
    SKIN:Bang('!SetOption', 'Bar' .. i, 'H', h)
    SKIN:Bang('!SetOption', 'Bar' .. i, 'Y', 142 - h)
  end
  SKIN:Bang('!SetVariable', 'Label', Library.label(load))
  return load
end

function Greeting(name)
  return SELF:GetOption('Greeting') .. ', ' .. name .. ' (Lua ' .. _VERSION:sub(5) .. ')'
end

function Weekday(offset)
  local names = { 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' }
  return names[(tonumber(os.date('%w')) + offset) % 7 + 1]
end

function Click()
  clicks = clicks + 1
  SKIN:Bang('!SetVariable', 'Clicks', clicks)
end
