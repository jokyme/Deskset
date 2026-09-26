-- Stack probe fixture (original content, see docs/skin-threading.md "Stack depth").
function Initialize() end
function Update() return 0 end

-- Nested pcalls add C stack frames; the innermost call asks the host for a meter's width (layout, text measuring).
function deep(n)
  if n <= 0 then
    local m = SKIN:GetMeter('T1')
    if m then return m:GetW() end
    return 1
  end
  local ok, v = pcall(deep, n - 1)
  if ok then return v end
  return 0
end
