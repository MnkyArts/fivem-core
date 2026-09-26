--[[
    core/tests/raycast_tests.lua — Core.Raycast (DESIGN §6.9, §42) against native stubs.

        lua5.4 tests/raycast_tests.lua    (from the resource directory, or from tests/)

    One client VM (import.lua + client/raycast.lua). The natives the file calls are faked
    below with the shapes fxref prints on their "Lua:" line, so this proves argument
    validation, the probe geometry and the BOOL rule of §30.4 (an out-value is the
    integer 0/1 on the default invoke route, a boolean on the direct one) — never what
    the engine answers in game. Exit code is 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/raycast_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local v = stubs.vector3

local passed, failed = 0, 0

local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print('FAIL  ' .. label .. (detail and ('\n        ' .. detail) or ''))
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

local function near(actual, expected, label)
    local ok = actual ~= nil and math.abs(actual.x - expected.x) < 1e-6
        and math.abs(actual.y - expected.y) < 1e-6 and math.abs(actual.z - expected.z) < 1e-6
    return check(ok, label, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

local env = stubs.newEnv('client', 'core')
stubs.loadImport(env)

-- ------------------------------------------------------------------ native fakes ----
local probe = { calls = {}, result = nil }
env.StartExpensiveSynchronousShapeTestLosProbe = function(x1, y1, z1, x2, y2, z2, flags, entity, p8)
    probe.calls[#probe.calls + 1] = { from = v(x1, y1, z1), to = v(x2, y2, z2), flags = flags, entity = entity, p8 = p8 }
    return 77
end
env.GetShapeTestResult = function(handle)
    probe.handle = handle
    local r = probe.result
    if not r then return 2, 0, v(0.0, 0.0, 0.0), v(0.0, 0.0, 0.0), 0 end   -- a miss, default route
    return 2, r.hit, r.coords, r.normal, r.entity
end

local screen = { origin = v(1.0, 2.0, 3.0), normal = v(0.0, 2.0, 0.0), calls = 0 }
env.GetWorldCoordFromScreenCoord = function(x, y)
    screen.calls = screen.calls + 1
    screen.args = { x, y }
    return screen.origin, screen.normal
end

local projection = { ok = 1, x = 0.25, y = 0.75, calls = 0 }
env.GetScreenCoordFromWorldCoord = function(x, y, z)
    projection.calls = projection.calls + 1
    projection.args = { x, y, z }
    return projection.ok, projection.x, projection.y
end

local cam = { coord = v(10.0, 20.0, 30.0), rot = v(0.0, 0.0, 0.0) }
env.GetFinalRenderedCamCoord = function() return cam.coord end
env.GetFinalRenderedCamRot = function(order)
    cam.order = order
    return cam.rot
end
env.GetGameplayCamCoord = function() return v(-5.0, -5.0, 0.0) end
env.GetGameplayCamRot = function() return v(0.0, 0.0, 0.0) end

stubs.loadFile(env, 'client/raycast.lua')
local Raycast = env.Core.Raycast
local function lastProbe() return probe.calls[#probe.calls] end
local function probes() return #probe.calls end
local hit, coords, normal, entity
local marks = {}                    -- call counters sampled before a refusal

-- ------------------------------------------------------------------ between (§6.9) ----
probe.result = nil
hit, coords, normal, entity = Raycast.between(v(0.0, 0.0, 0.0), v(0.0, 10.0, 0.0))
eq(hit, false, 'between: the integer 0 out-value is a miss, not a hit')
near(coords, v(0.0, 10.0, 0.0), 'between: a miss answers the end point')
eq(entity, 0, 'between: a miss answers entity 0')
eq(lastProbe().flags, -1, 'between: flags default to -1')
eq(lastProbe().entity, 0, 'between: nothing is ignored by default')
eq(lastProbe().p8, 7, 'between: p8 is the gameplay probe option')
probe.result = { hit = 1, coords = v(0.0, 4.0, 0.0), normal = v(0.0, -1.0, 0.0), entity = 55 }
hit, coords, normal, entity = Raycast.between(v(0.0, 0.0, 0.0), v(0.0, 10.0, 0.0), 1, 9)
eq(hit, true, 'between: the integer 1 out-value is a hit')
near(coords, v(0.0, 4.0, 0.0), 'between: a hit answers the hit point')
near(normal, v(0.0, -1.0, 0.0), 'between: and the surface normal')
eq(entity, 55, 'between: and the entity')
eq(lastProbe().flags, 1, 'between: flags pass through')
eq(lastProbe().entity, 9, 'between: the ignored entity passes through')
probe.result = { hit = true, coords = v(1.0, 1.0, 1.0), normal = v(0.0, 0.0, 1.0), entity = 0 }
eq((Raycast.between(v(0.0, 0.0, 0.0), v(0.0, 0.0, 5.0))), true, 'between: a boolean true (direct route) is a hit')
probe.result = { hit = false, coords = v(1.0, 1.0, 1.0), normal = v(0.0, 0.0, 1.0), entity = 0 }
eq((Raycast.between(v(0.0, 0.0, 0.0), v(0.0, 0.0, 5.0))), false, 'between: a boolean false is a miss')
marks.before = probes()
eq((Raycast.between({ x = 0, y = 0, z = 0 }, v(0.0, 0.0, 1.0))), false, 'between: a plain table is not a vector3')
eq(probes(), marks.before, 'between: and no probe is cast')
probe.result = nil

-- ------------------------------------------------------------------ screenToWorld ----
local origin, direction = Raycast.screenToWorld(0.5, 0.25)
near(origin, v(1.0, 2.0, 3.0), 'screenToWorld: the origin is the native world vector')
near(direction, v(0.0, 1.0, 0.0), 'screenToWorld: the direction is normalised')
eq(screen.args[1], 0.5, 'screenToWorld: fx reaches the native')
eq(screen.args[2], 0.25, 'screenToWorld: fy reaches the native')
eq(math.type(screen.args[1]), 'float', 'screenToWorld: the native gets floats')
Raycast.screenToWorld(0, 1)
eq(math.type(screen.args[1]), 'float', 'screenToWorld: an integer 0 is passed as a float')
check((Raycast.screenToWorld(0.0, 0.0)) ~= nil, 'screenToWorld: the corner 0,0 is valid')
check((Raycast.screenToWorld(1.0, 1.0)) ~= nil, 'screenToWorld: the corner 1,1 is valid')
marks.calls = screen.calls
local bad = { { -0.01, 0.5 }, { 0.5, 1.01 }, { 0 / 0, 0.5 }, { math.huge, 0.5 }, { '0.5', 0.5 }, { nil, 0.5 }, { 0.5, nil } }
for i = 1, #bad do
    local o, d = Raycast.screenToWorld(bad[i][1], bad[i][2])
    check(o == nil and d == nil, ('screenToWorld: invalid point #%d answers nil, nil'):format(i))
end
eq(screen.calls, marks.calls, 'screenToWorld: an invalid point never reaches the native')
screen.normal = v(0.0, 0.0, 0.0)
origin, direction = Raycast.screenToWorld(0.5, 0.5)
check(origin ~= nil and direction == nil, 'screenToWorld: a zero normal has an origin but no direction')
screen.normal = nil
origin, direction = Raycast.screenToWorld(0.5, 0.5)
check(origin ~= nil and direction == nil, 'screenToWorld: a missing normal has no direction')
screen.origin = nil
origin, direction = Raycast.screenToWorld(0.5, 0.5)
check(origin == nil and direction == nil, 'screenToWorld: no origin, nothing at all')
screen.origin, screen.normal = v(1.0, 2.0, 3.0), v(0.0, 2.0, 0.0)

-- ------------------------------------------------------------------ worldToScreen ----
local onScreen, fx, fy = Raycast.worldToScreen(v(4.0, 5.0, 6.0))
eq(onScreen, true, 'worldToScreen: the integer 1 is on screen')
eq(fx, 0.25, 'worldToScreen: fx from the native')
eq(fy, 0.75, 'worldToScreen: fy from the native')
eq(projection.args[3], 6.0, 'worldToScreen: the point reaches the native')
projection.ok = true
eq((Raycast.worldToScreen(v(4.0, 5.0, 6.0))), true, 'worldToScreen: a boolean true is on screen')
projection.ok = false
onScreen, fx, fy = Raycast.worldToScreen(v(4.0, 5.0, 6.0))
check(onScreen == false and fx == nil and fy == nil, 'worldToScreen: off screen answers false, nil, nil')
projection.ok = 0
eq((Raycast.worldToScreen(v(4.0, 5.0, 6.0))), false, 'worldToScreen: the integer 0 is off screen (0 is truthy in Lua)')
projection.ok, projection.x = 1, 0 / 0
eq((Raycast.worldToScreen(v(4.0, 5.0, 6.0))), false, 'worldToScreen: a NaN coordinate is not on screen')
projection.x = 0.25
marks.calls = projection.calls
eq((Raycast.worldToScreen({ x = 1, y = 2, z = 3 })), false, 'worldToScreen: a plain table is refused')
eq((Raycast.worldToScreen(v(0 / 0, 0.0, 0.0))), false, 'worldToScreen: a NaN component is refused')
eq((Raycast.worldToScreen(nil)), false, 'worldToScreen: nil is refused')
eq(projection.calls, marks.calls, 'worldToScreen: refused coords never reach the native')

-- ------------------------------------------------------------------ fromScreen ----
probe.result = nil
hit, coords, normal, entity = Raycast.fromScreen(0.5, 0.5)
eq(hit, false, 'fromScreen: a miss')
near(lastProbe().from, v(1.0, 2.0, 3.0), 'fromScreen: the probe starts at the screen point')
near(lastProbe().to, v(1.0, 1002.0, 3.0), 'fromScreen: and runs 1000 m along the direction by default')
eq(lastProbe().flags, -1, 'fromScreen: flags default to -1')
eq(lastProbe().entity, 0, 'fromScreen: nothing is ignored by default')
probe.result = { hit = 1, coords = v(1.0, 40.0, 3.0), normal = v(0.0, -1.0, 0.0), entity = 12 }
hit, coords, normal, entity = Raycast.fromScreen(0.5, 0.5, 50, 16, 99)
eq(hit, true, 'fromScreen: a hit')
near(coords, v(1.0, 40.0, 3.0), 'fromScreen: the hit point')
eq(entity, 12, 'fromScreen: the entity')
near(lastProbe().to, v(1.0, 52.0, 3.0), 'fromScreen: a custom distance')
eq(lastProbe().flags, 16, 'fromScreen: custom flags')
eq(lastProbe().entity, 99, 'fromScreen: a custom ignored entity')
check((Raycast.fromScreen(0.5, 0.5, 5000)) ~= nil and lastProbe().to.y == 5002.0, 'fromScreen: 5000 m is the limit, inclusive')
probe.result = nil
marks.before = probes()
local invalid = {
    { 0.5, 0.5, 0 }, { 0.5, 0.5, -1 }, { 0.5, 0.5, 5000.5 }, { 0.5, 0.5, 0 / 0 }, { 0.5, 0.5, '10' },
    { 0.5, 0.5, 10, 1.5 }, { 0.5, 0.5, 10, 'all' }, { 0.5, 0.5, 10, -1, 2.25 }, { 0.5, 0.5, 10, -1, {} },
    { 1.5, 0.5 }, { 0.5, -0.5 }, { 'x', 0.5 },
}
for i = 1, #invalid do
    local a = invalid[i]
    local h, c, n, e = Raycast.fromScreen(a[1], a[2], a[3], a[4], a[5])
    check(h == false and c == nil and n == nil and e == 0, ('fromScreen: invalid arguments #%d answer false, nil, nil, 0'):format(i))
end
eq(probes(), marks.before, 'fromScreen: invalid arguments never cast a probe')
screen.normal = v(0.0, 0.0, 0.0)
eq((Raycast.fromScreen(0.5, 0.5)), false, 'fromScreen: no direction, no probe')
eq(probes(), marks.before, 'fromScreen: and nothing was cast')
screen.normal = v(0.0, 2.0, 0.0)
Raycast.fromScreen(0.5, 0.5, 10, 1.0, 3.0)
check(math.type(lastProbe().flags) == 'integer' and math.type(lastProbe().entity) == 'integer',
    'fromScreen: whole floats are passed as integers')

-- ------------------------------------------------------------------ fromRenderedCamera ----
eq((Raycast.fromRenderedCamera()), false, 'fromRenderedCamera: a miss')
eq(cam.order, 2, 'fromRenderedCamera: rotation order 2')
near(lastProbe().from, v(10.0, 20.0, 30.0), 'fromRenderedCamera: the probe starts at the rendered camera')
near(lastProbe().to, v(10.0, 1020.0, 30.0), 'fromRenderedCamera: heading 0 looks along +Y, 1000 m by default')
eq(lastProbe().entity, 0, 'fromRenderedCamera: nothing is ignored by default (unlike fromCamera)')
cam.rot = v(90.0, 0.0, 0.0)
Raycast.fromRenderedCamera(10)
near(lastProbe().to, v(10.0, 20.0, 40.0), 'fromRenderedCamera: pitch 90 looks straight up')
cam.rot = v(0.0, 0.0, 90.0)
Raycast.fromRenderedCamera(10, 4, 7)
near(lastProbe().to, v(0.0, 20.0, 30.0), 'fromRenderedCamera: heading 90 looks along -X')
eq(lastProbe().flags, 4, 'fromRenderedCamera: custom flags')
eq(lastProbe().entity, 7, 'fromRenderedCamera: a custom ignored entity')
cam.coord, cam.rot = v(100.0, 0.0, 5.0), v(0.0, 0.0, 0.0)
Raycast.fromRenderedCamera(1)
near(lastProbe().from, v(100.0, 0.0, 5.0), 'fromRenderedCamera: follows whatever camera renders (a scripted one)')
probe.result = { hit = 1, coords = v(100.0, 0.5, 5.0), normal = v(0.0, -1.0, 0.0), entity = 3 }
hit, coords, normal, entity = Raycast.fromRenderedCamera(1)
check(hit == true and entity == 3, 'fromRenderedCamera: a hit answers the entity')
probe.result = nil
marks.before = probes()
for i, d in ipairs({ 0, -2, 5001, 0 / 0, math.huge, 'far' }) do
    local h, c, n, e = Raycast.fromRenderedCamera(d)
    check(h == false and c == nil and n == nil and e == 0, ('fromRenderedCamera: invalid distance #%d is refused'):format(i))
end
eq((Raycast.fromRenderedCamera(10, 0.5)), false, 'fromRenderedCamera: fractional flags are refused')
eq((Raycast.fromRenderedCamera(10, -1, 'me')), false, 'fromRenderedCamera: a non-number ignore is refused')
eq(probes(), marks.before, 'fromRenderedCamera: refused arguments never cast a probe')
cam.coord = nil
eq((Raycast.fromRenderedCamera(10)), false, 'fromRenderedCamera: no camera coordinate, no probe')
eq(probes(), marks.before, 'fromRenderedCamera: and nothing was cast')
cam.coord = v(10.0, 20.0, 30.0)

-- ------------------------------------------------------------------ fromCamera (§6.9) ----
Raycast.fromCamera(5)
near(lastProbe().from, v(-5.0, -5.0, 0.0), 'fromCamera: still the gameplay camera')
near(lastProbe().to, v(-5.0, 0.0, 0.0), 'fromCamera: 5 m along its heading')
eq(lastProbe().entity, env.PlayerPedId(), 'fromCamera: ignores the local ped by default')

print(('raycast: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end

-- end of file
