function Update()
  local ok, message = pcall(function()
    local numbers = {}
    for i = 1, 1e9 do numbers[i] = i end
  end)
  if not ok then return 'caught: ' .. message end
  return 'no limit?'
end
