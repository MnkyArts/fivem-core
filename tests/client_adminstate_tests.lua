--[[
    core/tests/client_adminstate_tests.lua — client/adminstate.lua (DESIGN §51, review F1): the client's own
    staff state and, while on duty, the on-duty staff map, fed by core:admin:self / staffState / staffStates;
    the hooks staffSelfChanged / staffStateChanged and the proxy Core.Admin.getSelf / getStaffStates.

        lua5.4 tests/client_adminstate_tests.lua    (from the resource directory, or from tests/)

    Exit code 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/client_adminstate_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local passed, failed = 0, 0

local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print(('FAIL  %s%s'):format(label, detail and ('\n        ' .. detail) or ''))
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

stubs.newWorld()
stubs.clear()
stubs.resetNui()
stubs.tick(1000)
local env = stubs.newEnv('client', 'core')
local Core = stubs.loadImport(env)
stubs.loadFile(env, 'shared/config.lua')
stubs.loadFile(env, 'client/api.lua')
stubs.loadFile(env, 'client/adminstate.lua')
local A = Core.Admin

local selfSeen, staffSeen = {}, {}
Core.on('staffSelfChanged', function(state) selfSeen[#selfSeen + 1] = state end)
Core.on('staffStateChanged', function(src, state) staffSeen[#staffSeen + 1] = { src = src, state = state } end)
local function server(name, payload) stubs.triggerOn(env, name, 65535, payload) end
local function count(map)
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    return n
end

-- start: nothing known
eq(A.getSelf().duty, false, 'off duty before the server says anything')
eq(next(A.getSelf().modes), nil, 'no modes')
eq(next(A.getStaffStates()), nil, 'no staff map')

-- a staff map entry before this client is on duty is ignored
server('core:admin:staffState', { src = 7, duty = true, modes = { vanish = true } })
eq(next(A.getStaffStates()), nil, 'staffState is ignored while off duty')
server('core:admin:staffStates', { { src = 7, duty = true, modes = {} } })
eq(next(A.getStaffStates()), nil, 'staffStates is ignored while off duty')

-- going on duty
server('core:admin:self', { duty = true, modes = { noclip = true, ['bad mode'] = true, x = { 1 } } })
eq(A.getSelf().duty, true, 'core:admin:self sets duty')
eq(A.getSelf().modes.noclip, true, '... and the modes')
eq(A.getSelf().modes['bad mode'], nil, 'an invalid mode name is dropped')
eq(A.getSelf().modes.x, nil, 'a non-true mode value is dropped')
eq(#selfSeen, 1, 'staffSelfChanged fired')
eq(selfSeen[1].duty, true, '... with the state')
selfSeen[1].modes.noclip = false
eq(A.getSelf().modes.noclip, true, 'the hook gets a copy')

server('core:admin:staffStates', {
    { src = 3, duty = true, modes = { vanish = true } }, { src = 4, duty = true, modes = {} },
    { src = 0, duty = true }, { src = 'x', duty = true }, 'garbage',
})
local map = A.getStaffStates()
eq(count(map), 2, 'the full list fills the map (invalid entries dropped)')
eq(map[3] and map[3].modes.vanish, true, 'entry 3 with its modes')
eq(#staffSeen, 2, 'staffStateChanged fired per entry')
map[3].modes.vanish = false
eq(A.getStaffStates()[3].modes.vanish, true, 'getStaffStates hands out copies')

-- changes
staffSeen = {}
server('core:admin:staffState', { src = 3, duty = true, modes = { vanish = true, spectate = true } })
eq(A.getStaffStates()[3].modes.spectate, true, 'a staffState updates the entry')
eq(staffSeen[1] and staffSeen[1].src, 3, '... and fires the hook')
server('core:admin:staffState', { src = 4, duty = false })
eq(A.getStaffStates()[4], nil, 'duty = false removes the entry')
eq(staffSeen[2] and staffSeen[2].state, nil, '... and the hook says nil')
server('core:admin:staffState', { src = 9, duty = false })
eq(#staffSeen, 2, 'removing an unknown entry fires nothing')
server('core:admin:staffState', 'nope')
eq(#staffSeen, 2, 'a malformed payload is ignored')

-- a fresh full list replaces the map
staffSeen = {}
server('core:admin:staffStates', { { src = 5, duty = true, modes = {} } })
local replaced = A.getStaffStates()
check(replaced[5] and not replaced[3], 'a new full list replaces the old map')
eq(staffSeen[1] and staffSeen[1].src, 3, 'the missing entry is reported gone first')
eq(staffSeen[1] and staffSeen[1].state, nil, '... as nil')

-- the proxy reaches the client namespace
local viaExport = stubs.exports.core.call('some_plugin', 'Admin', 'getSelf')
eq(viaExport and viaExport.duty, true, 'Core.Admin.getSelf through the client export')
local mapViaExport = stubs.exports.core.call('some_plugin', 'Admin', 'getStaffStates')
check(mapViaExport and mapViaExport[5] ~= nil, 'Core.Admin.getStaffStates through the client export')

-- going off duty drops the map
staffSeen = {}
server('core:admin:self', { duty = false, modes = {} })
eq(A.getSelf().duty, false, 'off duty')
eq(next(A.getStaffStates()), nil, 'the staff map is dropped')
eq(staffSeen[1] and staffSeen[1].src, 5, 'each dropped entry is reported')
eq(staffSeen[1] and staffSeen[1].state, nil, '... as nil')
eq(selfSeen[#selfSeen].duty, false, 'staffSelfChanged reports off duty')
server('core:admin:self', 'bad')
eq(A.getSelf().duty, false, 'a malformed self payload is ignored')
eq(#stubs.failures, 0, 'no handler errored')

print(('client adminstate: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
