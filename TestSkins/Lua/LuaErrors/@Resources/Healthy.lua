n = 0
function Update()
  n = n + 1
  return 'ok ' .. math.min(n, 3)
end
