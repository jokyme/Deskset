import Foundation

/// Operations of the single host function the prelude calls (`host(op, ...)`). The numbers are part of the
/// prelude below; keep both in sync.
enum LuaHostOp: Int {
    case getMeasure = 1          // (name) → canonical name | nil
    case getMeter = 2            // (name) → canonical name | nil
    case getVariable = 3         // (name) → value | nil
    case skinGeometry = 4        // ('x'|'y'|'w'|'h') → number
    case moveWindow = 5          // (x, y)
    case fadeWindow = 6          // (from, to)
    case bang = 7                // (bang, args...) or (action text)
    case makePathAbsolute = 8    // (path) → path
    case replaceVariables = 9    // (text) → text
    case parseFormula = 10       // (formula) → number | nil
    case getOption = 11          // (kind, section, option, replaceSectionVariables) → string | nil
    case getNumberOption = 12    // (kind, section, option) → number | nil
    case measureValue = 13       // (measure, 'value'|'string'|'relative'|'range'|'min'|'max') → value
    case measureEnable = 14      // (measure, enabled)
    case meterGeometry = 15      // (meter, 'x'|'y'|'w'|'h', absolute) → number
    case meterSet = 16           // (meter, 'x'|'y'|'w'|'h', value)
    case meterVisible = 17       // (meter, visible)
    case meterSetText = 18       // (meter, text)
    case print = 19              // (text)
    case readScript = 20         // (path) → source, chunk name | nil, message
    case fixPath = 21            // (path) → path
    case execute = 22            // (command) → status
}

/// Section kinds passed to `getOption` / `getNumberOption`.
enum LuaSectionKind: Int {
    case measure = 1
    case meter = 2
}

/// The Lua code run in every script state before the script itself: Rainmeter's `SKIN` object, the `SELF`
/// measure object, Measure and Meter objects (manual: /manual/lua-scripting/ "Functions"), `print` to the skin
/// log, the deprecated `PROPERTIES` table and `tolua.cast`, plus the macOS adaptations documented in
/// docs/compat/lua.md (paths, `os.date('%#d')`, `os.getenv`, `os.execute`, `dofile` decoding).
///
/// The chunk receives the host function and returns a table of internal functions the engine calls
/// (`start`, `properties`). Everything else it defines is local, so scripts cannot reach the host function
/// except through the documented objects.
enum LuaPrelude {
    static let chunkName = "=deskset"

    static let source = #"""
local host = ...
local type, tostring, tonumber, select, error, setmetatable, pairs, rawget, loadstring, unpack =
      type, tostring, tonumber, select, error, setmetatable, pairs, rawget, loadstring, unpack
local concat = table.concat
local format, gsub, find, sub, upper = string.format, string.gsub, string.find, string.sub, string.upper

local NAME, KIND = {}, {}
local MEASURE, METER = 1, 2

-- MARK: Measure and meter objects

local Measure, Meter, Skin = {}, {}, {}
local MeasureMeta = { __index = Measure, __metatable = false }
local MeterMeta = { __index = Meter, __metatable = false }
MeasureMeta.__tostring = function(h) return 'Measure: ' .. tostring(rawget(h, NAME)) end
MeterMeta.__tostring = function(h) return 'Meter: ' .. tostring(rawget(h, NAME)) end

local function handle(meta, kind, name)
  return setmetatable({ [NAME] = name, [KIND] = kind }, meta)
end

local function check(self, kind, method)
  if type(self) ~= 'table' or rawget(self, KIND) ~= kind then
    local object = kind == MEASURE and 'Measure' or 'Meter'
    error(format("%s:%s() must be called with ':' on a %s object", object, method, object), 3)
  end
  return rawget(self, NAME)
end

function Measure:GetName() return check(self, MEASURE, 'GetName') end
function Measure:GetValue() return host(13, check(self, MEASURE, 'GetValue'), 'value') end
function Measure:GetStringValue() return host(13, check(self, MEASURE, 'GetStringValue'), 'string') end
function Measure:GetRelativeValue() return host(13, check(self, MEASURE, 'GetRelativeValue'), 'relative') end
function Measure:GetValueRange() return host(13, check(self, MEASURE, 'GetValueRange'), 'range') end
function Measure:GetMinValue() return host(13, check(self, MEASURE, 'GetMinValue'), 'min') end
function Measure:GetMaxValue() return host(13, check(self, MEASURE, 'GetMaxValue'), 'max') end
function Measure:GetOption(option, default, replace)
  local v = host(11, MEASURE, check(self, MEASURE, 'GetOption'), option, replace ~= false)
  if v == nil then
    if default == nil then return '' end
    return default
  end
  return v
end
function Measure:GetNumberOption(option, default)
  local v = host(12, MEASURE, check(self, MEASURE, 'GetNumberOption'), option)
  if v == nil then
    if default == nil then return 0 end
    return default
  end
  return v
end
function Measure:Disable() host(14, check(self, MEASURE, 'Disable'), false) end
function Measure:Enable() host(14, check(self, MEASURE, 'Enable'), true) end

function Meter:GetName() return check(self, METER, 'GetName') end
function Meter:GetOption(option, default, replace)
  local v = host(11, METER, check(self, METER, 'GetOption'), option, replace ~= false)
  if v == nil then
    if default == nil then return '' end
    return default
  end
  return v
end
function Meter:GetNumberOption(option, default)
  local v = host(12, METER, check(self, METER, 'GetNumberOption'), option)
  if v == nil then
    if default == nil then return 0 end
    return default
  end
  return v
end
function Meter:GetX(absolute) return host(15, check(self, METER, 'GetX'), 'x', absolute and true or false) end
function Meter:GetY(absolute) return host(15, check(self, METER, 'GetY'), 'y', absolute and true or false) end
function Meter:GetW() return host(15, check(self, METER, 'GetW'), 'w', false) end
function Meter:GetH() return host(15, check(self, METER, 'GetH'), 'h', false) end
function Meter:SetX(value) host(16, check(self, METER, 'SetX'), 'x', value) end
function Meter:SetY(value) host(16, check(self, METER, 'SetY'), 'y', value) end
function Meter:SetW(value) host(16, check(self, METER, 'SetW'), 'w', value) end
function Meter:SetH(value) host(16, check(self, METER, 'SetH'), 'h', value) end
function Meter:Hide() host(17, check(self, METER, 'Hide'), false) end
function Meter:Show() host(17, check(self, METER, 'Show'), true) end
-- Deprecated (manual): use SKIN:Bang('!SetOption', 'MeterName', 'Text', '...').
function Meter:SetText(text) host(18, check(self, METER, 'SetText'), text) end

-- MARK: SKIN

local skinObject = setmetatable({}, { __index = Skin, __metatable = false,
                                      __tostring = function() return 'Skin' end })

local function checkSkin(self, method)
  if self ~= skinObject then
    error(format("SKIN:%s() must be called with ':'", method), 3)
  end
end

function Skin:GetMeasure(name)
  checkSkin(self, 'GetMeasure')
  local n = host(1, name)
  if n == nil then return nil end
  return handle(MeasureMeta, MEASURE, n)
end
function Skin:GetMeter(name)
  checkSkin(self, 'GetMeter')
  local n = host(2, name)
  if n == nil then return nil end
  return handle(MeterMeta, METER, n)
end
function Skin:GetVariable(name, default)
  checkSkin(self, 'GetVariable')
  local v = host(3, name)
  if v == nil then return default end
  return v
end
function Skin:GetX() checkSkin(self, 'GetX') return host(4, 'x') end
function Skin:GetY() checkSkin(self, 'GetY') return host(4, 'y') end
function Skin:GetW() checkSkin(self, 'GetW') return host(4, 'w') end
function Skin:GetH() checkSkin(self, 'GetH') return host(4, 'h') end
function Skin:MoveWindow(x, y) checkSkin(self, 'MoveWindow') host(5, x, y) end
function Skin:FadeWindow(from, to) checkSkin(self, 'FadeWindow') host(6, from, to) end
function Skin:Bang(...) checkSkin(self, 'Bang') host(7, ...) end
function Skin:MakePathAbsolute(path) checkSkin(self, 'MakePathAbsolute') return host(8, path) end
function Skin:ReplaceVariables(text) checkSkin(self, 'ReplaceVariables') return host(9, text) end
function Skin:ParseFormula(text) checkSkin(self, 'ParseFormula') return host(10, text) end

SKIN = skinObject

-- Deprecated tolua.cast(object, type) of old scripts: the objects need no cast.
tolua = { cast = function(object) return object end }

-- MARK: Standard library adaptations

print = function(...)
  local n = select('#', ...)
  local parts = {}
  for i = 1, n do parts[i] = tostring((select(i, ...))) end
  host(19, concat(parts, '\t'))
end

local function fixPath(path)
  if type(path) == 'string' then return host(21, path) end
  return path
end

local open, lines, input, output = io.open, io.lines, io.input, io.output
local remove, rename = os.remove, os.rename

-- Windows opens files in text mode unless the mode has 'b': "\r\n" is read as "\n". macOS has no text mode, so
-- reads from files not opened in binary mode convert line ends the same way (lines never end in "\r").
local fileMethods = getmetatable(io.stdout).__index
local rawRead, rawFileLines = fileMethods.read, fileMethods.lines
local binaryFiles = setmetatable({}, { __mode = 'k' })
local function textLine(line)
  if type(line) == 'string' then return (gsub(line, '\r$', '')) end
  return line
end
fileMethods.read = function(file, ...)
  if binaryFiles[file] then return rawRead(file, ...) end
  local n = select('#', ...)
  local results = { rawRead(file, ...) }
  for i = 1, (n > 0 and n or 1) do
    local v = results[i]
    if type(v) == 'string' then
      local format = n > 0 and select(i, ...) or '*l'
      v = gsub(v, '\r\n', '\n')
      if format == '*l' or format == '*L' then v = gsub(v, '\r$', '') end
      results[i] = v
    end
  end
  return unpack(results, 1, n > 0 and n or 1)
end
fileMethods.lines = function(file, ...)
  local iterator = rawFileLines(file, ...)
  if binaryFiles[file] then return iterator end
  return function() return textLine(iterator()) end
end

io.open = function(path, mode, ...)
  local file, message, code = open(fixPath(path), mode, ...)
  if file and type(mode) == 'string' and find(mode, 'b', 1, true) then binaryFiles[file] = true end
  return file, message, code
end
io.lines = function(path, ...)
  local iterator
  if path == nil then iterator = lines() else iterator = lines(fixPath(path), ...) end
  return function() return textLine(iterator()) end
end
io.read = function(...) return fileMethods.read(input(), ...) end
io.input = function(file) return input(fixPath(file)) end
io.output = function(file) return output(fixPath(file)) end
os.remove = function(path) return remove(fixPath(path)) end
os.rename = function(from, to) return rename(fixPath(from), fixPath(to)) end
-- Nothing may read the app's standard input (io.read() without io.input, or io.stdin:read(), would wait for it
-- when the app runs from a terminal): the default input and io.stdin read /dev/null.
if pcall(input, '/dev/null') then io.stdin = input() end

local function loadScript(path)
  if type(path) ~= 'string' then return nil, 'file name expected' end
  local source, name = host(20, path)
  if source == nil then return nil, name end
  return loadstring(source, name)
end
loadfile = function(path) return loadScript(path) end
dofile = function(path)
  local chunk, message = loadScript(path)
  if chunk == nil then error(message, 2) end
  return chunk()
end

os.execute = function(command)
  if command == nil then return 0 end
  return host(22, command)
end

local getenv = os.getenv
local windowsEnvironment = {
  USERNAME = function() return getenv('USER') end,
  USERPROFILE = function() return getenv('HOME') end,
  HOMEPATH = function() return getenv('HOME') end,
  HOMEDRIVE = function() return '' end,
  APPDATA = function() local h = getenv('HOME') return h and (h .. '/Library/Application Support') end,
  LOCALAPPDATA = function() local h = getenv('HOME') return h and (h .. '/Library/Application Support') end,
  TEMP = function() return getenv('TMPDIR') end,
  TMP = function() return getenv('TMPDIR') end,
  PROGRAMFILES = function() return '/Applications' end,
}
os.getenv = function(name)
  local v = getenv(name)
  if v ~= nil or type(name) ~= 'string' then return v end
  local mapped = windowsEnvironment[upper(name)]
  if mapped then return mapped() end
  return nil
end

-- os.date: the Windows '#' flag ("%#d", "%#H": no leading zero) is not known to the C library on macOS.
local date = os.date
local function expandHashFlags(fmt, t)
  local utc = sub(fmt, 1, 1) == '!' and '!' or ''
  local out, i, n = {}, 1, #fmt
  while i <= n do
    local c = sub(fmt, i, i)
    if c == '%' and i < n then
      local d = sub(fmt, i + 1, i + 1)
      if d == '#' and i + 2 <= n then
        local v = date(utc .. '%' .. sub(fmt, i + 2, i + 2), t)
        if find(v, '^%d+$') then v = (gsub(v, '^0+(%d)', '%1')) end
        out[#out + 1] = (gsub(v, '%%', '%%%%'))
        i = i + 3
      else
        out[#out + 1] = c .. d
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return concat(out)
end
os.date = function(fmt, t)
  if type(fmt) == 'string' and find(fmt, '%#', 1, true) then fmt = expandHashFlags(fmt, t) end
  if fmt == nil then return date() end
  return date(fmt, t)
end

-- string.rep('', huge) would spin in C where the instruction limit cannot stop it.
local rep = string.rep
string.rep = function(s, n, ...)
  if s == '' then return '' end
  return rep(s, n, ...)
end

-- MARK: Internal functions (called by the engine)

local internal = {}

function internal.start(name)
  SELF = handle(MeasureMeta, MEASURE, name)
end

-- Deprecated PROPERTIES = { Option = default, ... }: filled with the measure's options before Initialize().
function internal.properties(name)
  local props = rawget(_G, 'PROPERTIES')
  if type(props) ~= 'table' then return end
  local keys = {}
  for k in pairs(props) do
    if type(k) == 'string' then keys[#keys + 1] = k end
  end
  for i = 1, #keys do
    local k = keys[i]
    local v
    if type(props[k]) == 'number' then
      v = host(12, MEASURE, name, k)
    else
      v = host(11, MEASURE, name, k, true)
    end
    if v ~= nil then props[k] = v end
  end
end

return internal
"""#
}
