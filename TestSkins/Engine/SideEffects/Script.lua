-- Writes a file of the skin's own, renames it and removes it again, then does the same with a temporary file
-- (os.tmpname): on the Mac nothing is left, in a recording five changes are recorded.
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
    local tmp = os.tmpname()
    local t = io.open(tmp, 'w')
    if t then
        t:write('scratch')
        t:close()
    end
    os.remove(tmp)
    SKIN:Bang('!SetVariable', 'TmpName', tmp)
    state = 'touched'
end
