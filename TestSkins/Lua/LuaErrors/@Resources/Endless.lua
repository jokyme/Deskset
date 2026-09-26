function Update()
  local i = 0
  while true do
    i = i + 1
    pcall(function() while true do end end)
  end
end
