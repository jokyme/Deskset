-- Helper library loaded with dofile (original test fixture for Deskset).
Library = { version = '1.2' }

function Library.split(text, separator)
  local parts = {}
  for part in string.gmatch(text or '', '[^' .. separator .. ']+') do parts[#parts + 1] = part end
  return parts
end

function Library.label(value)
  if value < 40 then return 'Calm' elseif value < 70 then return 'Busy' end
  return 'Peak'
end
