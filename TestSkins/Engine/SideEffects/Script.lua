-- Writes a file of the skin's own, renames it and removes it again: on the Mac nothing is left, in a recording three
-- changes are recorded.
local state = 'waiting'

function Update()
    return state
end

function Touch()
    local path = SKIN:MakePathAbsolute('new.txt')
    local moved = SKIN:MakePathAbsolute('moved.txt')
    local f = io.open(path, 'w')
    if f then
        f:write('written')
        f:close()
    end
    os.rename(path, moved)
    os.remove(moved)
    state = 'touched'
end
