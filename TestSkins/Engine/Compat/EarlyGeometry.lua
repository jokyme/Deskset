-- Original fixture for Deskset (EarlyGeometry.ini): meter geometry read in Initialize(), during the first update and
-- before the meters are laid out.
function Initialize()
  local title = SKIN:GetMeter('Title')
  local badge = SKIN:GetMeter('Badge')
  seen = string.format('title %dx%d, badge at x=%d', title:GetW(), title:GetH(), badge:GetX())
end

function Update()
  return seen
end
