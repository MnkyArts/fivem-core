--[[
    core/tests/scene_motion_tests.lua — offline suite for Core.SceneMotion (DESIGN §55.9, scene INTERFACES §3).

        lua5.4 tests/scene_motion_tests.lua    (from the resource directory, or from tests/)

    validate() defaults, normalisation and rejections (too many points / keys, NaN, zero durations, …); every
    primitive (tween + eases, path linear / catmull × once / loop / pingpong × face, spin, osc, orbit, keys linear
    / smooth / loop, dr) at key times, with velocity() and finished(); loop and pingpong boundaries; t wrapping
    across 2^32 (and 2^31); constant speed along catmull paths (±1 %); pose() allocating nothing; and the SAME
    numbers from a server VM and a client VM (stubs.newEnv('server'|'client', 'core')). Exit code 1 on failure.
]]

local here = (arg and arg[0] or 'tests/scene_motion_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local passed, failed = 0, 0

local function show(v)
    if type(v) == 'string' then return ('%q'):format(v) end
    return tostring(v)
end

local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print(('FAIL  [scene_motion] %s%s'):format(label, detail and ('\n        ' .. detail) or ''))
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label, ('expected %s, got %s'):format(show(expected), show(actual)))
end

local function near(actual, expected, label, tolerance)
    return check(type(actual) == 'number' and math.abs(actual - expected) <= (tolerance or 1e-6), label,
        ('expected ~%s, got %s'):format(show(expected), show(actual)))
end

--- pose(...) against an expected x, y, z, rx, ry, rz, moving (angles compared modulo 360).
local function pose(label, expect, x, y, z, rx, ry, rz, moving)
    local function angleNear(a, b)
        local d = (a - b) % 360
        return math.min(d, 360 - d) <= 1e-6
    end
    local ok = math.abs(x - expect[1]) <= 1e-6 and math.abs(y - expect[2]) <= 1e-6 and math.abs(z - expect[3]) <= 1e-6
        and angleNear(rx, expect[4]) and angleNear(ry, expect[5]) and angleNear(rz, expect[6])
        and (expect[7] == nil or moving == expect[7])
    return check(ok, label, ('expected (%s), got (%s, %s, %s, %s, %s, %s, %s)'):format(
        table.concat({ table.unpack(expect, 1, 6) }, ', ') .. ', ' .. tostring(expect[7]),
        x, y, z, rx, ry, rz, tostring(moving)))
end

local frame, netTime = 1, 0

--- A core VM with import.lua and the motion module. Client VMs get the two client clock natives.
local function newVM(side, config)
    local env = stubs.newEnv(side, 'core')
    if side == 'client' then
        env.GetFrameCount = function() return frame end
        env.GetNetworkTimeAccurate = function() return netTime end
    end
    env.Config = config
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/scene_motion.lua')
    return env, env.Core.SceneMotion, env.Core.Clock
end

local function copy(v)   -- a deep copy: what a descriptor looks like after the wire
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, item in pairs(v) do out[k] = copy(item) end
    return out
end

stubs.newWorld()
stubs.clear()
stubs.tick(100000)
local _, M, Clock = newVM('server')

local function valid(desc, label)
    local ok, out = M.validate(desc)
    check(ok == true and type(out) == 'table', 'validate: ' .. label, not ok and tostring(out) or nil)
    return out
end

local function rejects(desc, code, label)
    local ok, err = M.validate(desc)
    return check(ok == false and err == code, 'validate rejects ' .. label,
        ('expected false, %s; got %s, %s'):format(code, tostring(ok), show(err)))
end

--------------------------------------------------------------------------------
-- validate: defaults, normalisation, rejections
--------------------------------------------------------------------------------

local nan = 0 / 0
rejects(nil, 'bad_desc', 'a non-table')
rejects({}, 'bad_type', 'a missing type')
rejects({ t = 'warp' }, 'bad_type', 'an unknown type')
rejects({ t = 'spin', t0 = 1.5, dps = 1 }, 'bad_t0', 'a fractional t0')
rejects({ t = 'spin', t0 = nan, dps = 1 }, 'bad_t0', 'a NaN t0')
rejects({ t = 'spin', t0 = 'soon', dps = 1 }, 'bad_t0', 'a string t0')
eq(valid({ t = 'spin', t0 = -1, dps = 1 }, 'negative t0').t0, 0xFFFFFFFF, 't0 is masked to u32')
eq(valid({ t = 'spin', t0 = 7.0, dps = 1 }, 'integral float t0').t0, 7, 'an integral float t0 becomes an integer')
eq(math.type(valid({ t = 'spin', t0 = 7.0, dps = 1 }, 'float t0 type').t0), 'integer', 't0 is an integer')
eq(valid({ t = 'spin', dps = 1 }, 'default t0').t0, Clock.at(200), 't0 defaults to Clock.at(200)')
eq(valid({ t = 'dr', p = { 0, 0, 0 }, v = { 1, 0, 0 } }, 'dr default t0').t0, Clock.now(), 'a dr sample defaults to now')
local _, Mc, ClockC = newVM('server', { Scene = { Motion = { PlanLeadMs = 350 } } })
eq(select(2, Mc.validate({ t = 'spin', dps = 1 })).t0, ClockC.at(350), 't0 default follows Config.Scene.Motion.PlanLeadMs')

-- tween
rejects({ t = 'tween', t0 = 0, d = 0, to = { 1, 2, 3 } }, 'bad_duration', 'a zero duration')
rejects({ t = 'tween', t0 = 0, d = -5, to = { 1, 2, 3 } }, 'bad_duration', 'a negative duration')
rejects({ t = 'tween', t0 = 0, d = nan, to = { 1, 2, 3 } }, 'bad_duration', 'a NaN duration')
rejects({ t = 'tween', t0 = 0, d = 2 ^ 31, to = { 1, 2, 3 } }, 'bad_duration', 'a duration over 2^30 ms')
rejects({ t = 'tween', t0 = 0, d = 10, e = 'bounce', to = { 1, 2, 3 } }, 'bad_ease', 'an unknown ease')
rejects({ t = 'tween', t0 = 0, d = 10 }, 'bad_to', 'a missing target')
rejects({ t = 'tween', t0 = 0, d = 10, to = { x = nan, y = 0, z = 0 } }, 'bad_to', 'a NaN target')
rejects({ t = 'tween', t0 = 0, d = 10, to = { 1, 2, 3, math.huge } }, 'bad_to', 'an infinite target angle')
rejects({ t = 'tween', t0 = 0, d = 10, to = { 1, 2, 3 }, from = { 1, 2 } }, 'bad_from', 'a short from')
local tw = valid({ t = 'tween', t0 = 0, d = 10, to = { 1, 2, 3, 190 } }, 'positional target with an angle')
check(tw.e == 'linear' and tw.to.x == 1 and tw.to.rx == -170 and tw.to.ry == nil, 'tween defaults: linear ease, angles normalised')
local tv = valid({ t = 'tween', t0 = 0, d = 10, to = stubs.vector3(4, 5, 6) }, 'a vector3 target')
check(tv.to.x == 4 and tv.to.z == 6, 'a vector3 target is copied')

-- path
local pts65 = {}
for i = 1, 65 do pts65[i] = { i, 0, 0 } end
rejects({ t = 'path', t0 = 0, pts = pts65, sp = 1 }, 'too_many_points', '65 points')
pts65[65] = nil
check(M.validate({ t = 'path', t0 = 0, pts = pts65, sp = 1 }), 'validate accepts 64 points')
rejects({ t = 'path', t0 = 0, pts = { { 1, 2, 3 } }, sp = 1 }, 'bad_points', 'a single point')
rejects({ t = 'path', t0 = 0, pts = { { 1, 2, 3 }, { 1, 2, 3.0005 } }, sp = 1 }, 'bad_points', 'two points 0.5 mm apart')
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { nan, 1, 1 } }, sp = 1 }, 'bad_point', 'a NaN point')
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 1e6, 1, 1 } }, sp = 1 }, 'bad_point', 'a point 1,000 km out')
rejects({ t = 'path', t0 = 0, pts = { [1] = { 0, 0, 0 }, [3] = { 1, 1, 1 } }, sp = 1 }, 'bad_points', 'a sparse point list')
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 5, 0, 0 } }, sp = 1, d = 5 }, 'bad_timing', 'both sp and d')
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 5, 0, 0 } } }, 'bad_timing', 'neither sp nor d')
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 5, 0, 0 } }, sp = 0 }, 'bad_speed', 'a zero speed')
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 5, 0, 0 } }, d = 0 }, 'bad_duration', 'a zero path duration')
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 5000, 0, 0 } }, sp = 1e-5 }, 'bad_duration', 'a pass over 2^30 ms')
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 5, 0, 0 } }, sp = 1, loop = 'bounce' }, 'bad_loop', 'an unknown loop')
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 5, 0, 0 } }, sp = 1, curve = 'bezier' }, 'bad_curve', 'an unknown curve')
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 5, 0, 0 } }, sp = 1, face = 'up' }, 'bad_face', 'an unknown face')
local input = { t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 0, 0, 0 }, { 5, 0, 0 }, { 5, 5, 0 }, { 0, 0, 0 } }, d = 100, loop = 'loop' }
local path = valid(input, 'a closed path with duplicates')
eq(#path.pts, 3, 'consecutive duplicates merge and a closing repeat of the first point is dropped')
check(path.pts[1].x == 0 and path.pts[3].y == 5 and path.curve == 'linear' and path.face == 'fixed',
    'path defaults: linear curve, fixed facing; points become { x, y, z }')
eq(#input.pts, 5, 'validate never mutates its input')
eq(valid({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 5, 0, 0 } }, sp = 1 }, 'default loop').loop, 'once', "loop defaults to 'once'")

-- spin / osc / orbit / keys / dr
rejects({ t = 'spin', t0 = 0, axis = 'w', dps = 1 }, 'bad_axis', 'an unknown axis')
rejects({ t = 'spin', t0 = 0, dps = nan }, 'bad_dps', 'a NaN spin rate')
rejects({ t = 'spin', t0 = 0, dps = 1e6 }, 'bad_dps', 'a spin rate over 36,000°/s')
eq(valid({ t = 'spin', t0 = 0, dps = 5 }, 'default axis').axis, 'z', "axis defaults to 'z'")
rejects({ t = 'osc', t0 = 0, dir = { 0, 0, 0 }, amp = 1, period = 10 }, 'bad_dir', 'a zero direction')
rejects({ t = 'osc', t0 = 0, dir = { 0, 0, 1 }, amp = nan, period = 10 }, 'bad_amp', 'a NaN amplitude')
rejects({ t = 'osc', t0 = 0, dir = { 0, 0, 1 }, amp = 1, period = 0 }, 'bad_period', 'a zero period')
rejects({ t = 'osc', t0 = 0, dir = { 0, 0, 1 }, amp = 1, period = 10, phase = nan }, 'bad_phase', 'a NaN phase')
local osc = valid({ t = 'osc', t0 = 0, dir = { 0, 0, 2 }, amp = 1, period = 10, phase = 450 }, 'osc')
check(osc.dir.z == 1 and osc.phase == 90, 'osc: direction normalised to a unit vector, phase to (-180, 180]')
rejects({ t = 'orbit', t0 = 0, c = { 0, 0 }, r = 1, period = 10 }, 'bad_center', 'a short centre')
rejects({ t = 'orbit', t0 = 0, c = { 0, 0, 0 }, r = 0, period = 10 }, 'bad_radius', 'a zero radius')
rejects({ t = 'orbit', t0 = 0, c = { 0, 0, 0 }, r = 1, period = -1 }, 'bad_period', 'a negative period')
rejects({ t = 'orbit', t0 = 0, c = { 0, 0, 0 }, r = 1, period = 10, a0 = nan }, 'bad_angle', 'a NaN start angle')
rejects({ t = 'orbit', t0 = 0, c = { 0, 0, 0 }, r = 1, period = 10, face = 'up' }, 'bad_face', 'an unknown orbit face')
local keys129 = {}
for i = 1, 129 do keys129[i] = { t = i * 10, x = i, y = 0, z = 0 } end
rejects({ t = 'keys', t0 = 0, keys = keys129 }, 'too_many_keys', '129 keys')
keys129[129] = nil
check(M.validate({ t = 'keys', t0 = 0, keys = keys129 }), 'validate accepts 128 keys')
rejects({ t = 'keys', t0 = 0, keys = { { t = 0, x = 0, y = 0, z = 0 } } }, 'bad_keys', 'a single key')
rejects({ t = 'keys', t0 = 0, keys = { { t = 5, x = 0, y = 0, z = 0 }, { t = 5, x = 1, y = 0, z = 0 } } },
    'bad_key_time', 'key times that do not increase')
rejects({ t = 'keys', t0 = 0, keys = { { t = -1, x = 0, y = 0, z = 0 }, { t = 5, x = 1, y = 0, z = 0 } } },
    'bad_key_time', 'a negative key time')
rejects({ t = 'keys', t0 = 0, keys = { { t = 0, x = 0, y = 0, z = 0 }, { t = 5, x = nan, y = 0, z = 0 } } },
    'bad_key', 'a NaN key position')
local kp = valid({ t = 'keys', t0 = 0, keys = { { 0, 1, 2, 3 }, { 100, 4, 5, 6, 0, 0, 270 } } }, 'positional keys')
check(kp.keys[2].t == 100 and kp.keys[2].x == 4 and kp.keys[2].rz == -90 and kp.loop == false and kp.smooth == false,
    'positional keys: { t, x, y, z, rx, ry, rz }; loop / smooth default false')
rejects({ t = 'dr', t0 = 0, p = { 0, 0 }, v = { 0, 0, 0 } }, 'bad_p', 'a short dr position')
rejects({ t = 'dr', t0 = 0, p = { 0, 0, 0 }, v = { nan, 0, 0 } }, 'bad_v', 'a NaN dr velocity')
rejects({ t = 'dr', t0 = 0, p = { 0, 0, 0 }, v = { 0, 0, 0 }, yaw = nan }, 'bad_yaw', 'a NaN yaw')

--------------------------------------------------------------------------------
-- primitives at key times (Δt from t0 = T)
--------------------------------------------------------------------------------

local T = 5000
local function vel(label, ex, ey, ez, vx, vy, vz, tolerance)
    local tol = tolerance or 1e-6
    return check(math.abs(vx - ex) <= tol and math.abs(vy - ey) <= tol and math.abs(vz - ez) <= tol, label,
        ('expected (%s, %s, %s), got (%s, %s, %s)'):format(ex, ey, ez, vx, vy, vz))
end

-- tween
local tl = valid({ t = 'tween', t0 = T, d = 1000, to = { x = 10, y = 20, z = -30, rz = 90 } }, 'tween')
pose('tween before t0 holds the base, not moving', { 1, 2, 3, 4, 5, 6, false }, M.pose(1, 2, 3, 4, 5, 6, tl, T - 100))
pose('tween at t0 starts at the base, moving', { 1, 2, 3, 4, 5, 6, true }, M.pose(1, 2, 3, 4, 5, 6, tl, T))
pose('tween halfway (linear); axes missing in `to` keep the start', { 5.5, 11, -13.5, 4, 5, 48, true },
    M.pose(1, 2, 3, 4, 5, 6, tl, T + 500))
local ex, ey, ez, erx, ery, erz, emoving = M.pose(1, 2, 3, 4, 5, 6, tl, T + 1000)
check(ex == 10 and ey == 20 and ez == -30 and erx == 4 and ery == 5 and erz == 90 and emoving == false,
    'an ended tween lands EXACTLY on its target and stops moving')
pose('a long-ended tween holds the target', { 10, 20, -30, 4, 5, 90, false }, M.pose(1, 2, 3, 4, 5, 6, tl, T + 99999))
vel('tween velocity with the base position', 9, 18, -33, M.velocity(tl, T + 500, 1, 2, 3))
vel('tween without `from` and without a base reports 0', 0, 0, 0, M.velocity(tl, T + 500))
vel('an ended tween has no velocity', 0, 0, 0, M.velocity(tl, T + 1000, 1, 2, 3))
check(not M.finished(tl, T + 999) and M.finished(tl, T + 1000), 'tween finished exactly at t0 + d')
for _, c in ipairs({ { 'in', 500, 1.25 }, { 'out', 500, 8.75 }, { 'inout', 500, 5 }, { 'inout', 250, 0.625 },
    { 'inout', 750, 9.375 } }) do
    local d = valid({ t = 'tween', t0 = T, d = 1000, e = c[1], to = { 10, 0, 0 } }, 'ease ' .. c[1])
    near((M.pose(0, 0, 0, 0, 0, 0, d, T + c[2])), c[3], ('ease %s at u = %.2f'):format(c[1], c[2] / 1000))
end
local ein = valid({ t = 'tween', t0 = T, d = 1000, e = 'in', to = { 10, 0, 0 } }, 'ease in')
vel("the 'in' ease velocity at u = 0.5 (3u² · 10 m/s)", 7.5, 0, 0, M.velocity(ein, T + 500, 0, 0, 0))
local wrapRot = valid({ t = 'tween', t0 = T, d = 1000, to = { 0, 0, 0, 0, 0, -170 } }, 'tween across ±180')
pose('a tween turns the short way across ±180', { 0, 0, 0, 0, 0, 180, true }, M.pose(0, 0, 0, 0, 0, 170, wrapRot, T + 500))
local from = valid({ t = 'tween', t0 = T, d = 1000, from = { x = 100, y = 0, z = 0, rz = 10 }, to = { 200, 0, 0 } }, 'tween from')
pose('an explicit `from` replaces the base (its missing angles stay the base)', { 150, 0, 0, 4, 5, 10, true },
    M.pose(1, 2, 3, 4, 5, 6, from, T + 500))
vel('velocity of a tween with `from` needs no base', 100, 0, 0, M.velocity(from, T + 500))

-- path, linear, once, facing the travel
local pl = valid({ t = 'path', t0 = T, pts = { { 0, 0, 0 }, { 100, 0, 0 }, { 100, 100, 0 } }, sp = 10, face = 'path' }, 'path')
pose('path before t0: the start, facing the first segment (east = -90)', { 0, 0, 0, 7, 8, -90, false },
    M.pose(0, 0, 0, 7, 8, 9, pl, T - 1))
pose('path at t0', { 0, 0, 0, 7, 8, -90, true }, M.pose(0, 0, 0, 7, 8, 9, pl, T))
pose('path after 5 s at 10 m/s', { 50, 0, 0, 7, 8, -90, true }, M.pose(0, 0, 0, 7, 8, 9, pl, T + 5000))
pose('path at the corner faces the next segment (north = 0)', { 100, 0, 0, 7, 8, 0, true }, M.pose(0, 0, 0, 7, 8, 9, pl, T + 10000))
pose('path on the second segment', { 100, 50, 0, 7, 8, 0, true }, M.pose(0, 0, 0, 7, 8, 9, pl, T + 15000))
pose("a 'once' path ends on its last point, not moving", { 100, 100, 0, 7, 8, 0, false }, M.pose(0, 0, 0, 7, 8, 9, pl, T + 20000))
pose('and holds it', { 100, 100, 0, 7, 8, 0, false }, M.pose(0, 0, 0, 7, 8, 9, pl, T + 90000))
vel('path velocity on the first segment', 10, 0, 0, M.velocity(pl, T + 5000))
vel('path velocity on the second segment', 0, 10, 0, M.velocity(pl, T + 15000))
vel('an ended path has no velocity', 0, 0, 0, M.velocity(pl, T + 20000))
check(not M.finished(pl, T + 19999) and M.finished(pl, T + 20000), "a 'once' path finishes after one pass")
local plFixed = copy(pl)
plFixed.face = 'fixed'
pose("face 'fixed' keeps the base rotation", { 50, 0, 0, 7, 8, 9, true }, M.pose(0, 0, 0, 7, 8, 9, plFixed, T + 5000))

-- closed loop (a square, one lap = 4 s)
local sq = valid({ t = 'path', t0 = T, pts = { { 0, 0, 0 }, { 10, 0, 0 }, { 10, 10, 0 }, { 0, 10, 0 } }, d = 4000, loop = 'loop' }, 'loop')
pose('loop: first corner after 1 s', { 10, 0, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, sq, T + 1000))
pose('loop: the closing segment runs back to the start', { 0, 5, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, sq, T + 3500))
pose('loop: one lap later it is at the start again', { 0, 0, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, sq, T + 4000))
pose('loop: and continues', { 10, 0, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, sq, T + 5000))
pose('loop: after 1,000 laps', { 5, 0, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, sq, T + 4000000 + 500))
vel('loop velocity on the closing segment', 0, -10, 0, M.velocity(sq, T + 3500))
eq(M.finished(sq, T + 1e8), false, 'a loop never finishes')

-- pingpong
local pp = valid({ t = 'path', t0 = T, pts = { { 0, 0, 0 }, { 10, 0, 0 } }, d = 1000, loop = 'pingpong', face = 'path' }, 'pingpong')
pose('pingpong outbound', { 5, 0, 0, 0, 0, -90, true }, M.pose(0, 0, 0, 0, 0, 0, pp, T + 500))
pose('pingpong turns at the end (now facing west)', { 10, 0, 0, 0, 0, 90, true }, M.pose(0, 0, 0, 0, 0, 0, pp, T + 1000))
pose('pingpong inbound', { 5, 0, 0, 0, 0, 90, true }, M.pose(0, 0, 0, 0, 0, 0, pp, T + 1500))
vel('pingpong inbound velocity', -10, 0, 0, M.velocity(pp, T + 1500))
pose('pingpong back at the start', { 0, 0, 0, 0, 0, -90, true }, M.pose(0, 0, 0, 0, 0, 0, pp, T + 2000))
vel('pingpong outbound again', 10, 0, 0, M.velocity(pp, T + 2500))
eq(M.finished(pp, T + 1e8), false, 'pingpong never finishes')

-- spin
local sp = valid({ t = 'spin', t0 = T, dps = 90 }, 'spin')
pose('spin before t0', { 1, 2, 3, 0, 0, 10, false }, M.pose(1, 2, 3, 0, 0, 10, sp, T - 1))
pose('spin 1 s at 90°/s', { 1, 2, 3, 0, 0, 100, true }, M.pose(1, 2, 3, 0, 0, 10, sp, T + 1000))
pose('spin normalises past 180', { 1, 2, 3, 0, 0, -80, true }, M.pose(1, 2, 3, 0, 0, 10, sp, T + 3000))
pose('spin about x, backwards', { 0, 0, 0, -45, 0, 0, true },
    M.pose(0, 0, 0, 0, 0, 0, valid({ t = 'spin', t0 = T, axis = 'x', dps = -45 }, 'spin x'), T + 1000))
pose('spin about y', { 0, 0, 0, 0, 30, 0, true },
    M.pose(0, 0, 0, 0, 0, 0, valid({ t = 'spin', t0 = T, axis = 'y', dps = 30 }, 'spin y'), T + 1000))
vel('a spin has no linear velocity', 0, 0, 0, M.velocity(sp, T + 1000))
eq(M.finished(sp, T + 1e8), false, 'a spin never finishes')
local still = valid({ t = 'spin', t0 = T, dps = 0 }, 'spin 0')
check(M.finished(still, T) and select(7, M.pose(0, 0, 0, 0, 0, 0, still, T + 5)) == false, 'a 0°/s spin is finished and not moving')

-- osc
local os1 = valid({ t = 'osc', t0 = T, dir = { 0, 0, 1 }, amp = 2, period = 4000 }, 'osc')
pose('osc before t0 holds its start', { 1, 1, 1, 0, 0, 0, false }, M.pose(1, 1, 1, 0, 0, 0, os1, T - 5))
pose('osc quarter period: +amp', { 1, 1, 3, 0, 0, 0, true }, M.pose(1, 1, 1, 0, 0, 0, os1, T + 1000))
pose('osc half period: back at the base', { 1, 1, 1, 0, 0, 0, true }, M.pose(1, 1, 1, 0, 0, 0, os1, T + 2000))
pose('osc three quarters: -amp', { 1, 1, -1, 0, 0, 0, true }, M.pose(1, 1, 1, 0, 0, 0, os1, T + 3000))
vel('osc velocity at t0 = amp · 2π / period', 0, 0, math.pi, M.velocity(os1, T))
vel('osc velocity at the crest is 0', 0, 0, 0, M.velocity(os1, T + 1000))
pose('osc phase 90° starts at the crest', { 1, 1, 3, 0, 0, 0, true },
    M.pose(1, 1, 1, 0, 0, 0, valid({ t = 'osc', t0 = T, dir = { 0, 0, 1 }, amp = 2, period = 4000, phase = 90 }, 'osc phase'), T))
local r2 = math.sqrt(2)
pose('osc along a diagonal (unit direction)', { 1 + r2, 1 + r2, 1, 0, 0, 0, true },
    M.pose(1, 1, 1, 0, 0, 0, valid({ t = 'osc', t0 = T, dir = { 1, 1, 0 }, amp = 2, period = 4000 }, 'osc diagonal'), T + 1000))
eq(M.finished(os1, T + 1e8), false, 'an osc never finishes')

-- orbit (headings around the centre: 0 = north of it, counter-clockwise)
local ob = valid({ t = 'orbit', t0 = T, c = { 10, 20, 5 }, r = 5, period = 8000 }, 'orbit')
pose('orbit starts north of the centre', { 10, 25, 5, 0, 0, 9, true }, M.pose(0, 0, 0, 0, 0, 9, ob, T))
pose('orbit quarter: west', { 5, 20, 5, 0, 0, 9, true }, M.pose(0, 0, 0, 0, 0, 9, ob, T + 2000))
pose('orbit half: south', { 10, 15, 5, 0, 0, 9, true }, M.pose(0, 0, 0, 0, 0, 9, ob, T + 4000))
pose('orbit three quarters: east', { 15, 20, 5, 0, 0, 9, true }, M.pose(0, 0, 0, 0, 0, 9, ob, T + 6000))
pose('orbit full lap', { 10, 25, 5, 0, 0, 9, true }, M.pose(0, 0, 0, 0, 0, 9, ob, T + 8000))
pose('orbit before t0 holds the start, not moving', { 10, 25, 5, 0, 0, 9, false }, M.pose(0, 0, 0, 0, 0, 9, ob, T - 1))
local obPath = copy(ob)
obPath.face = 'path'
pose("orbit face 'path' at the north point heads west (90)", { 10, 25, 5, 0, 0, 90, true }, M.pose(0, 0, 0, 0, 0, 0, obPath, T))
pose("orbit face 'path' at the west point heads south (180)", { 5, 20, 5, 0, 0, 180, true }, M.pose(0, 0, 0, 0, 0, 0, obPath, T + 2000))
local obCenter = copy(ob)
obCenter.face = 'center'
pose("orbit face 'center' from the north looks south", { 10, 25, 5, 0, 0, 180, true }, M.pose(0, 0, 0, 0, 0, 0, obCenter, T))
pose("orbit face 'center' from the west looks east", { 5, 20, 5, 0, 0, -90, true }, M.pose(0, 0, 0, 0, 0, 0, obCenter, T + 2000))
local obCw = valid({ t = 'orbit', t0 = T, c = { 10, 20, 5 }, r = 5, period = 8000, cw = true, face = 'path' }, 'orbit cw')
pose('orbit cw quarter: east, heading south', { 15, 20, 5, 0, 0, 180, true }, M.pose(0, 0, 0, 0, 0, 0, obCw, T + 2000))
pose('orbit cw at the start heads east (-90)', { 10, 25, 5, 0, 0, -90, true }, M.pose(0, 0, 0, 0, 0, 0, obCw, T))
pose('orbit a0 = 90 starts west', { 5, 20, 5, 0, 0, 0, true },
    M.pose(0, 0, 0, 0, 0, 0, valid({ t = 'orbit', t0 = T, c = { 10, 20, 5 }, r = 5, period = 8000, a0 = 90 }, 'orbit a0'), T))
local tangential = 5 * 2 * math.pi / 8
vel('orbit velocity at the north point (counter-clockwise → west)', -tangential, 0, 0, M.velocity(ob, T))
vel('orbit cw velocity at the north point (→ east)', tangential, 0, 0, M.velocity(obCw, T))
eq(M.finished(ob, T + 1e8), false, 'an orbit never finishes')

-- keys, linear
local kl = valid({ t = 'keys', t0 = T, keys = { { t = 0, x = 0, y = 0, z = 0, rz = 0 }, { t = 1000, x = 10, y = 0, z = 0, rz = 90 },
    { t = 3000, x = 10, y = 20, z = 0, rz = 180 } } }, 'keys')
pose('keys before t0: the first key, not moving', { 0, 0, 0, 0, 0, 0, false }, M.pose(0, 0, 0, 0, 0, 0, kl, T - 5))
pose('keys halfway through the first segment', { 5, 0, 0, 0, 0, 45, true }, M.pose(0, 0, 0, 0, 0, 0, kl, T + 500))
pose('keys halfway through the second (longer) segment', { 10, 10, 0, 0, 0, 135, true }, M.pose(0, 0, 0, 0, 0, 0, kl, T + 2000))
pose('keys end on the last key, not moving', { 10, 20, 0, 0, 0, 180, false }, M.pose(0, 0, 0, 0, 0, 0, kl, T + 3000))
pose('keys hold the last key', { 10, 20, 0, 0, 0, 180, false }, M.pose(0, 0, 0, 0, 0, 0, kl, T + 9000))
vel('keys velocity, segment 1', 10, 0, 0, M.velocity(kl, T + 500))
vel('keys velocity, segment 2', 0, 10, 0, M.velocity(kl, T + 2000))
vel('ended keys have no velocity', 0, 0, 0, M.velocity(kl, T + 3000))
check(not M.finished(kl, T + 2999) and M.finished(kl, T + 3000), 'keys finish at the last key time')
local late = valid({ t = 'keys', t0 = T, keys = { { t = 500, x = 1, y = 0, z = 0 }, { t = 1500, x = 2, y = 0, z = 0 } } }, 'late keys')
pose('before the first key time the first key holds', { 1, 0, 0, 0, 0, 0, false }, M.pose(0, 0, 0, 0, 0, 0, late, T + 200))
pose('keys after a late first key', { 1.5, 0, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, late, T + 1000))
local kturn = valid({ t = 'keys', t0 = T, keys = { { t = 0, x = 0, y = 0, z = 0, rz = 170 }, { t = 1000, x = 0, y = 0, z = 0, rz = -170 } } }, 'keys turn')
pose('keys turn the short way across ±180', { 0, 0, 0, 0, 0, 180, true }, M.pose(0, 0, 0, 0, 0, 0, kturn, T + 500))
pose('a key without angles takes the base angles', { 1.5, 0, 0, 11, 22, 33, true }, M.pose(0, 0, 0, 11, 22, 33, late, T + 1000))

-- keys, loop
local klp = valid({ t = 'keys', t0 = T, loop = true, keys = { { t = 0, x = 0, y = 0, z = 0 }, { t = 1000, x = 10, y = 0, z = 0 },
    { t = 2000, x = 0, y = 0, z = 0 } } }, 'keys loop')
pose('keys loop: second lap', { 5, 0, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, klp, T + 2500))
pose('keys loop: at the lap boundary', { 0, 0, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, klp, T + 4000))
pose('keys loop: 1 ms before the boundary', { 0.01, 0, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, klp, T + 1999))
pose('keys loop: 1 ms after it', { 0.01, 0, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, klp, T + 2001))
eq(M.finished(klp, T + 1e8), false, 'looping keys never finish')

-- keys, smooth (time-scaled Catmull-Rom)
local ks = valid({ t = 'keys', t0 = T, smooth = true, keys = { { t = 0, x = 0, y = 0, z = 0 }, { t = 1000, x = 10, y = 0, z = 0 },
    { t = 2000, x = 10, y = 10, z = 0 }, { t = 3000, x = 0, y = 10, z = 0 } } }, 'keys smooth')
pose('smooth keys pass exactly through a key', { 10, 0, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, ks, T + 1000))
pose('smooth keys pass through the next key', { 10, 10, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, ks, T + 2000))
pose('smooth keys bow outwards mid-segment (Hermite value)', { 11.25, 5, 0, 0, 0, 0, true }, M.pose(0, 0, 0, 0, 0, 0, ks, T + 1500))
local ax, ay = M.velocity(ks, T + 999)
local bx, by = M.velocity(ks, T + 1001)
check(math.abs(ax - bx) < 0.05 and math.abs(ay - by) < 0.05, 'smooth keys: velocity is continuous across a key',
    ('%s, %s vs %s, %s'):format(ax, ay, bx, by))
local ksl = valid({ t = 'keys', t0 = T, smooth = true, loop = true, keys = { { t = 0, x = 0, y = 0, z = 0 },
    { t = 1000, x = 10, y = 0, z = 0 }, { t = 2000, x = 10, y = 10, z = 0 }, { t = 3000, x = 0, y = 0, z = 0 } } }, 'keys smooth loop')
-- the seam tangent is (P2 - P(n-1)) / ((t2 - t1) + (tn - t(n-1))) = (0, -5) m/s from both sides (a linear loop
-- jumps from (-10, -10) to (10, 0) there); ±1 ms away the curve's acceleration moves it by a few cm/s only
ax, ay = M.velocity(ksl, T + 2999)
bx, by = M.velocity(ksl, T + 3001)
check(math.abs(ax) < 0.1 and math.abs(ay + 5) < 0.1 and math.abs(bx) < 0.1 and math.abs(by + 5) < 0.1,
    'smooth looping keys: velocity is continuous across the seam', ('%s, %s vs %s, %s'):format(ax, ay, bx, by))

-- dr
local dr = valid({ t = 'dr', t0 = T, p = { 1, 2, 3 }, v = { 10, 0, -1 }, yaw = 45 }, 'dr')
pose('dr extrapolates p + v·Δt', { 6, 2, 2.5, 0, 0, 45, true }, M.pose(0, 0, 0, 0, 0, 9, dr, T + 500))
pose('dr stops extrapolating after 1 s', { 11, 2, 2, 0, 0, 45, false }, M.pose(0, 0, 0, 0, 0, 9, dr, T + 1000))
pose('dr then holds', { 11, 2, 2, 0, 0, 45, false }, M.pose(0, 0, 0, 0, 0, 9, dr, T + 5000))
pose('a dr sample from the future holds p (still moving)', { 1, 2, 3, 0, 0, 45, true }, M.pose(0, 0, 0, 0, 0, 9, dr, T - 100))
vel('dr velocity while extrapolating', 10, 0, -1, M.velocity(dr, T + 500))
vel('dr velocity after the horizon', 0, 0, 0, M.velocity(dr, T + 1500))
check(not M.finished(dr, T + 999) and M.finished(dr, T + 1000), 'dr finishes at the 1 s horizon')
local drStill = valid({ t = 'dr', t0 = T, p = { 1, 2, 3 }, v = { 0, 0, 0 } }, 'dr still')
pose('dr without yaw keeps the base heading; v = 0 is not moving', { 1, 2, 3, 0, 0, 9, false }, M.pose(0, 0, 0, 0, 0, 9, drStill, T + 100))

-- nothing to evaluate
pose('pose(nil) is the base pose', { 1, 2, 3, 4, 5, 6, false }, M.pose(1, 2, 3, 4, 5, 6, nil, T))
pose('an unknown type is the base pose', { 1, 2, 3, 4, 5, 6, false }, M.pose(1, 2, 3, 4, 5, 6, { t = 'warp', t0 = 0 }, T))
vel('velocity(nil) is 0', 0, 0, 0, M.velocity(nil, T))
eq(M.finished(nil, T), true, 'finished(nil)')
eq(M.finished({ t = 'warp' }, T), true, 'an unknown type is finished')

--------------------------------------------------------------------------------
-- catmull: through the points, constant speed (±1 %), tangent = velocity = heading
--------------------------------------------------------------------------------

--- min / max / mean chord speed (m/s) over [from, to] in `step` ms, moving steps only.
local function speeds(desc, from, to, step)
    local lo, hi, sum, n = math.huge, 0, 0, 0
    local px, py, pz = M.pose(0, 0, 0, 0, 0, 0, desc, from)
    for t = from + step, to, step do
        local x, y, z, _, _, _, moving = M.pose(0, 0, 0, 0, 0, 0, desc, t)
        if moving then
            local s = math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2) / (step / 1000)
            lo, hi, sum, n = math.min(lo, s), math.max(hi, s), sum + s, n + 1
        end
        px, py, pz = x, y, z
    end
    return lo, hi, sum / n
end

local uneven = { { 0, 0, 0 }, { 5, 0, 0 }, { 5, 3, 0 }, { 30, 40, 2 }, { 60, 40, 0 }, { 70, 70, 10 } }
local cat = valid({ t = 'path', t0 = T, pts = uneven, sp = 7, curve = 'catmull', face = 'path' }, 'catmull path')
local lo, hi = speeds(cat, T, T + 60000, 10)
check(lo >= 7 * 0.99 and hi <= 7 * 1.01, 'catmull (uneven spacing, a 3 m hook): speed within ±1 % of sp',
    ('%.4f .. %.4f m/s'):format(lo, hi))
local closed = valid({ t = 'path', t0 = T, pts = { { 0, 0, 0 }, { 50, 0, 0 }, { 60, 30, 5 }, { 10, 40, 0 } }, d = 20000,
    loop = 'loop', curve = 'catmull' }, 'closed catmull')
local clo, chi, cmean = speeds(closed, T, T + 40000, 10)
check(clo >= cmean * 0.99 and chi <= cmean * 1.01, 'closed catmull loop: constant speed within ±1 % over two laps',
    ('%.4f .. %.4f (mean %.4f)'):format(clo, chi, cmean))
local llo, lhi = speeds(pl, T, T + 25000, 10)
check(math.abs(llo - 10) < 1e-6 and math.abs(lhi - 10) < 1e-6, 'a linear path is exactly constant speed')

local sx, sy, sz = M.pose(0, 0, 0, 0, 0, 0, cat, T)
check(sx == 0 and sy == 0 and sz == 0, 'catmull starts on the first point')
local fx2, fy2, fz2, _, _, _, fmoving = M.pose(0, 0, 0, 0, 0, 0, cat, T + 1e7)
check(math.abs(fx2 - 70) < 1e-9 and math.abs(fy2 - 70) < 1e-9 and math.abs(fz2 - 10) < 1e-9 and fmoving == false,
    'catmull ends on the last point')
local closest = { math.huge, math.huge, math.huge, math.huge }
for t = T, T + 20000, 1 do
    local x, y, z = M.pose(0, 0, 0, 0, 0, 0, cat, t)
    for i = 2, 5 do
        local p = uneven[i]
        local d = math.sqrt((x - p[1]) ^ 2 + (y - p[2]) ^ 2 + (z - p[3]) ^ 2)
        if d < closest[i - 1] then closest[i - 1] = d end
    end
end
check(math.max(table.unpack(closest)) < 0.005, 'catmull passes through every interior point (within 5 mm at 1 ms steps)',
    table.concat(closest, ', '))
local worstDir, worstHeading = 0, 0
for t = T + 100, T + 14000, 97 do
    local vx, vy, vz = M.velocity(cat, t)
    local x1, y1, z1 = M.pose(0, 0, 0, 0, 0, 0, cat, t - 1)
    local x2, y2, z2 = M.pose(0, 0, 0, 0, 0, 0, cat, t + 1)
    local rz = select(6, M.pose(0, 0, 0, 0, 0, 0, cat, t))
    local nx, ny, nz = (x2 - x1) / 0.002, (y2 - y1) / 0.002, (z2 - z1) / 0.002
    worstDir = math.max(worstDir, math.sqrt((vx - nx) ^ 2 + (vy - ny) ^ 2 + (vz - nz) ^ 2) / 7)
    local heading = math.deg(math.atan(-vx, vy))
    local dh = (rz - heading) % 360
    worstHeading = math.max(worstHeading, math.min(dh, 360 - dh))
end
check(worstDir < 0.01, 'catmull velocity() matches the numeric derivative of pose() (±1 %)', tostring(worstDir))
check(worstHeading < 1e-6, "catmull face 'path': rz is the GTA heading of the velocity", tostring(worstHeading))

--------------------------------------------------------------------------------
-- the clock wraps: t0 just below 2^32 (and 2^31), t after it — bit-identical results
--------------------------------------------------------------------------------

local battery = {
    { 'tween', tl }, { 'path', pl }, { 'loop', sq }, { 'pingpong', pp }, { 'spin', sp }, { 'osc', os1 }, { 'orbit', ob },
    { 'orbit path', obPath }, { 'keys', kl }, { 'keys loop', klp }, { 'keys smooth', ks }, { 'keys smooth loop', ksl },
    { 'dr', dr }, { 'catmull', cat }, { 'closed catmull', closed },
}
local MASK = 0xFFFFFFFF
local offsets = { -300, -1, 0, 1, 255, 256, 257, 999, 1000, 1500, 4321, 20000, 123456 }

local function same(a, b)
    for i = 1, math.max(a.n, b.n) do
        if a[i] ~= b[i] then return false end
    end
    return true
end

for _, anchor in ipairs({ 0xFFFFFF00, 0x7FFFFF00, 0xFFFFFFFF }) do
    local bad = {}
    for _, entry in ipairs(battery) do
        local desc = entry[2]
        local moved = copy(desc)
        moved.t0 = anchor
        for _, dt in ipairs(offsets) do
            local tw = (anchor + dt) & MASK
            local signed = tw >= 0x80000000 and tw - 0x100000000 or tw
            local want = table.pack(M.pose(1, 2, 3, 4, 5, 6, desc, T + dt))
            local got = table.pack(M.pose(1, 2, 3, 4, 5, 6, moved, tw))
            local gotSigned = table.pack(M.pose(1, 2, 3, 4, 5, 6, moved, signed))
            local wantV = table.pack(M.velocity(desc, T + dt, 1, 2, 3))
            local gotV = table.pack(M.velocity(moved, tw, 1, 2, 3))
            if not (same(want, got) and same(want, gotSigned) and same(wantV, gotV)
                and M.finished(desc, T + dt) == M.finished(moved, tw)) then
                bad[#bad + 1] = ('%s Δt=%d'):format(entry[1], dt)
            end
        end
    end
    check(#bad == 0, ('t0 = 0x%08X: every motion evaluates identically across the wrap (%d cases)')
        :format(anchor, #battery * #offsets), table.concat(bad, '; '))
end

--------------------------------------------------------------------------------
-- the same numbers in a server VM and a client VM
--------------------------------------------------------------------------------

frame, netTime = 7, 123456789
local _, MC = newVM('client')
for _, entry in ipairs(battery) do
    local serverDesc, clientDesc = entry[2], copy(entry[2])   -- the client gets it through the wire (a copy)
    local mismatches = 0
    for k = -10, 400 do
        local t = T + k * 37
        if not same(table.pack(M.pose(1, 2, 3, 4, 5, 6, serverDesc, t)), table.pack(MC.pose(1, 2, 3, 4, 5, 6, clientDesc, t)))
            or not same(table.pack(M.velocity(serverDesc, t, 1, 2, 3)), table.pack(MC.velocity(clientDesc, t, 1, 2, 3)))
            or M.finished(serverDesc, t) ~= MC.finished(clientDesc, t) then
            mismatches = mismatches + 1
        end
    end
    eq(mismatches, 0, ('server and client VMs: %s gives bit-identical poses, velocities, finished'):format(entry[1]))
end

local function deepEq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b and math.type(a) == math.type(b) end
    for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local raw = {
    { t = 'tween', t0 = 1, d = 500, e = 'out', to = { 1, 2, 3, 400 }, from = stubs.vector3(0, 0, 0) },
    { t = 'path', t0 = 2, pts = uneven, sp = 3, curve = 'catmull', loop = 'pingpong', face = 'path' },
    { t = 'spin', t0 = 3, axis = 'y', dps = -720 },
    { t = 'osc', t0 = 4, dir = { 1, 2, 2 }, amp = 0.5, period = 900, phase = -450 },
    { t = 'orbit', t0 = 5, c = { 1, 1, 1 }, r = 3, period = 700, a0 = 400, cw = true, face = 'center' },
    { t = 'keys', t0 = 6, keys = { { 0, 1, 1, 1 }, { 10, 2, 2, 2, 190 } }, smooth = true, loop = true },
    { t = 'dr', t0 = 7, p = { 1, 2, 3 }, v = { 4, 5, 6 }, yaw = -190 },
}
for _, desc in ipairs(raw) do
    local okS, outS = M.validate(desc)
    local okC, outC = MC.validate(desc)
    check(okS and okC and deepEq(outS, outC), ('validate normalises %s identically in both VMs'):format(desc.t))
end

local notIdempotent = {}
for _, entry in ipairs(battery) do
    local again, out = MC.validate(copy(entry[2]))
    if not (again and deepEq(out, entry[2])) then notIdempotent[#notIdempotent + 1] = entry[1] end
end
check(#notIdempotent == 0, 'validate() of a normalized descriptor changes no bit (a client may re-check what it receives)',
    table.concat(notIdempotent, ', '))

--------------------------------------------------------------------------------
-- pose / velocity / finished allocate nothing (the client movers call them every frame)
--------------------------------------------------------------------------------

for _, entry in ipairs(battery) do M.pose(0, 0, 0, 0, 0, 0, entry[2], T) end   -- path tables exist from here on
collectgarbage('collect')
collectgarbage('stop')
local before = collectgarbage('count')
for i = 1, 1000 do
    local t = T + i * 13
    for j = 1, #battery do
        local d = battery[j][2]
        M.pose(1, 2, 3, 4, 5, 6, d, t)
        M.velocity(d, t, 1, 2, 3)
        M.finished(d, t)
    end
end
local grown = math.floor((collectgarbage('count') - before) * 1024)
collectgarbage('restart')
check(grown == 0, ('pose / velocity / finished allocate nothing (%d bytes over %d calls)'):format(grown, 3000 * #battery))

--------------------------------------------------------------------------------
-- rebase / needsRebase: t0 moves to t, the future stays the same
--------------------------------------------------------------------------------

local TWO30, TWO31 = 1073741824, 2147483648

local anchored = copy(sp)
anchored.t0 = 1000
eq(M.needsRebase(anchored, 1000 + TWO30), false, 'needsRebase: exactly 2^30 ms after t0 is still fine')
eq(M.needsRebase(anchored, 1000 + TWO30 + 1), true, 'needsRebase: more than 2^30 ms (≈ 12.4 days) after t0')
eq(M.needsRebase(anchored, (1000 - TWO30 - 1) & MASK), true, 'needsRebase: a t0 more than 2^30 ms ahead too')
eq(M.needsRebase(anchored, 5000), false, 'needsRebase: a fresh descriptor')
eq(M.needsRebase(nil, 5000), false, 'needsRebase(nil)')
eq(M.needsRebase({ t = 'spin' }, 5000), false, 'needsRebase without a t0')

--- desc a and its rebase b agree at t + k for every k: pose (angles modulo 360), moving, velocity, finished.
local function sameFuture(a, b, t, offsets)
    for _, k in ipairs(offsets) do
        local tk = (t + k) & MASK
        local pa = table.pack(M.pose(1, 2, 3, 4, 5, 6, a, tk))
        local pb = table.pack(M.pose(1, 2, 3, 4, 5, 6, b, tk))
        for i = 1, 3 do
            if math.abs(pa[i] - pb[i]) > 1e-6 then return false, ('k=%d axis %d: %s vs %s'):format(k, i, pa[i], pb[i]) end
        end
        for i = 4, 6 do
            local d = (pa[i] - pb[i]) % 360
            if math.min(d, 360 - d) > 1e-6 then return false, ('k=%d angle %d: %s vs %s'):format(k, i, pa[i], pb[i]) end
        end
        if pa[7] ~= pb[7] then return false, ('k=%d moving %s vs %s'):format(k, tostring(pa[7]), tostring(pb[7])) end
        local va = table.pack(M.velocity(a, tk, 1, 2, 3))
        local vb = table.pack(M.velocity(b, tk, 1, 2, 3))
        for i = 1, 3 do
            if math.abs(va[i] - vb[i]) > 1e-6 then return false, ('k=%d velocity %d: %s vs %s'):format(k, i, va[i], vb[i]) end
        end
        if M.finished(a, tk) ~= M.finished(b, tk) then return false, ('k=%d finished'):format(k) end
    end
    return true
end

-- every motion, rebased at six ages up to 2^31 − 3·10^8 ms, compared at ten later times (up to 2^28 ms on)
local futures = { 0, 1, 17, 999, 1000, 1001, 4321, 123457, 9999999, 268435456 }
local ages = { 0, 1234, 3999, 1000007, TWO30 + 12345, TWO31 - 300000000 }
for _, entry in ipairs(battery) do
    local bad
    for _, age in ipairs(ages) do
        local t = (T + age) & MASK
        local ok, where = sameFuture(entry[2], M.rebase(entry[2], t), t, futures)
        if not ok then
            bad = ('age %d: %s'):format(age, where)
            break
        end
    end
    check(bad == nil, ('rebase keeps the future of %s identical (±1e-6)'):format(entry[1]), bad)
end
check(sameFuture(from, M.rebase(from, T + 5000), T + 5000, futures), 'rebase keeps a tween whose angle came from `from`')
local lateLoop = valid({ t = 'keys', t0 = T, loop = true, keys = { { t = 500, x = 0, y = 0, z = 0, rz = 10 },
    { t = 1500, x = 10, y = 0, z = 0, rz = 100 }, { t = 2700, x = 0, y = 0, z = 0, rz = 10 } } }, 'keys loop from 500 ms')
for _, entry in ipairs({ { 'a clockwise orbit', obCw }, { 'looping keys whose first key is at 500 ms', lateLoop } }) do
    local bad
    for _, age in ipairs(ages) do
        local t = (T + age) & MASK
        local ok, where = sameFuture(entry[2], M.rebase(entry[2], t), t, futures)
        if not ok then
            bad = ('age %d: %s'):format(age, where)
            break
        end
    end
    check(bad == nil, ('rebase keeps the future of %s identical (±1e-6)'):format(entry[1]), bad)
end

-- periodic motions: t0 lands on t and they need no rebase any more
for _, entry in ipairs({ { 'loop', sq }, { 'pingpong', pp }, { 'spin', sp }, { 'osc', os1 }, { 'orbit', ob },
    { 'keys loop', klp }, { 'keys smooth loop', ksl }, { 'closed catmull', closed } }) do
    local t = (T + TWO30 + 777) & MASK
    local r = M.rebase(entry[2], t)
    check(M.needsRebase(entry[2], t) and r.t0 == t and not M.needsRebase(r, t) and r.t == entry[2].t,
        ('a rebased %s keeps its type, starts at t and needs no rebase'):format(entry[1]))
end
local rsq = M.rebase(sq, (T + 5500) & MASK)
eq(rsq.ph, 1500, "a loop path keeps its phase in `ph` (5.5 s into a 4 s lap)")
eq(M.rebase(sq, (T + 8000) & MASK).ph, nil, 'a whole number of laps leaves no `ph`')
local rsp = M.rebase(sp, (T + 1000) & MASK)
eq(rsp.a0, 90, 'a spin folds the angle it turned into `a0` (1 s at 90°/s)')

-- the reason for rebasing: 1.5 s before Clock.diff wraps (2^31 ms after t0)
local A = 4000000000
for _, entry in ipairs({ { 'loop', sq, 4000 }, { 'pingpong', pp, 2000 }, { 'spin', sp, 4000 }, { 'osc', os1, 4000 },
    { 'orbit', ob, 8000 }, { 'keys loop', klp, 2000 } }) do
    local desc, period = copy(entry[2]), entry[3]
    desc.t0 = A
    local age = TWO31 - 1500
    local t = (A + age) & MASK
    local r = M.rebase(desc, t)
    local later = (t + 5000) & MASK                          -- 2^31 + 3.5 s after the original t0
    local ref = copy(entry[2])
    ref.t0 = 0                                               -- the same motion, the same phase, well inside the window
    local want = table.pack(M.pose(1, 2, 3, 4, 5, 6, ref, (age + 5000) % period))
    local got = table.pack(M.pose(1, 2, 3, 4, 5, 6, r, later))
    local stale = table.pack(M.pose(1, 2, 3, 4, 5, 6, desc, later))
    local good = got[7] == true
    for i = 1, 6 do
        local d = i <= 3 and math.abs(got[i] - want[i]) or math.min((got[i] - want[i]) % 360, (want[i] - got[i]) % 360)
        if d > 1e-6 then good = false end
    end
    check(M.needsRebase(desc, t) and good, ('%s rebased just before the 2^31 wrap continues on phase'):format(entry[1]))
    eq(stale[7], false, ('without the rebase the %s would read as "not started" after the wrap'):format(entry[1]))
end

-- finished motions become a 1 ms tween that ended at t − 1 on the exact end pose
local rt = M.rebase(tl, (T + 5000) & MASK)
check(rt.t == 'tween' and rt.d == 1 and rt.e == 'linear' and rt.t0 == ((T + 4999) & MASK) and rt.to.x == 10
    and rt.to.rz == 90 and rt.to.rx == nil and rt.from == nil,
    'a finished tween becomes a 1 ms tween that ended at t − 1 (an angle left to the base stays absent)')
check(M.finished(rt, (T + 5000) & MASK), 'which is finished from t on')
local rf = M.rebase(from, T + 5000)
check(rf.to.x == 200 and rf.to.rz == 10, 'a finished tween keeps the angle its `from` gave it')
local rpl = M.rebase(pl, (T + 25000) & MASK)
check(rpl.t == 'tween' and rpl.to.x == 100 and rpl.to.y == 100 and rpl.to.z == 0 and rpl.to.rz == 0,
    "a finished once path ends as a tween on its last point, facing its last heading (face 'path')")
eq(M.rebase(plFixed, (T + 25000) & MASK).to.rz, nil, "face 'fixed' leaves the heading to the base")
local rcat = M.rebase(cat, T + 60000)
local ex2, ey2, ez2, _, _, erz2 = M.pose(0, 0, 0, 0, 0, 0, cat, T + 60000)
check(rcat.to.x == ex2 and rcat.to.y == ey2 and rcat.to.z == ez2 and rcat.to.rz == erz2,
    'a finished catmull path ends exactly where pose() ends it')
local rkl = M.rebase(kl, (T + 4000) & MASK)
check(rkl.t == 'tween' and rkl.to.x == 10 and rkl.to.y == 20 and rkl.to.rz == 180 and rkl.to.rx == nil,
    'finished keys end as a tween on the last key')
local rdr = M.rebase(dr, (T + 1500) & MASK)
check(rdr.t == 'dr' and rdr.p.x == 11 and rdr.p.y == 2 and rdr.p.z == 2 and rdr.v.x == 0 and rdr.v.z == 0
    and rdr.yaw == 45 and rdr.t0 == ((T + 500) & MASK), 'a dr past its horizon is re-sampled: its held point, v = 0, at t − 1000')
check(M.finished(rdr, T + 1500) and select(7, M.pose(0, 0, 0, 0, 0, 0, rdr, T + 1500)) == false, 'and is finished and still')

-- running motions and plans that have not started come back unchanged (as copies)
local runningTween = M.rebase(tl, T + 500)
check(runningTween ~= tl and deepEq(runningTween, tl), 'a running tween comes back as an unchanged copy')
check(deepEq(M.rebase(pl, T + 5000), pl), 'a running once path comes back unchanged')
check(deepEq(M.rebase(kl, T + 2000), kl), 'running keys come back unchanged')
check(deepEq(M.rebase(dr, T + 500), dr), 'an extrapolating dr comes back unchanged')
check(deepEq(M.rebase(sp, T - 100), sp) and deepEq(M.rebase(sq, T - 1), sq), 'a plan that has not started keeps its t0')
eq(M.rebase(nil, T), nil, 'rebase(nil) is nil')
check(deepEq(M.rebase({ t = 'warp', t0 = 1 }, T), { t = 'warp', t0 = 1 }), 'an unknown type comes back as a copy')

-- never mutates, answers valid normalized descriptors, identically in both VMs
local sqBefore = copy(sq)
M.rebase(sq, (T + TWO30 + 5) & MASK)
check(deepEq(sq, sqBefore), 'rebase never mutates its input')
local invalid, differs = {}, {}
for _, entry in ipairs(battery) do
    local t = (T + TWO30 + 999) & MASK
    local r = M.rebase(entry[2], t)
    local okV, norm = M.validate(copy(r))
    if not (okV and deepEq(norm, r)) then invalid[#invalid + 1] = entry[1] end
    if not deepEq(r, MC.rebase(copy(entry[2]), t)) then differs[#differs + 1] = entry[1] end
end
check(#invalid == 0, 'every rebased descriptor validates to itself (already normalized)', table.concat(invalid, ', '))
check(#differs == 0, 'server and client VMs rebase identically', table.concat(differs, ', '))
rejects({ t = 'path', t0 = 0, pts = { { 0, 0, 0 }, { 5, 0, 0 } }, d = 10, ph = -1 }, 'bad_phase', 'a negative path phase')
rejects({ t = 'keys', t0 = 0, keys = { { 0, 0, 0, 0 }, { 5, 1, 0, 0 } }, ph = 0 / 0 }, 'bad_phase', 'a NaN keys phase')
rejects({ t = 'spin', t0 = 0, dps = 1, a0 = 0 / 0 }, 'bad_angle', 'a NaN spin start angle')

--------------------------------------------------------------------------------
-- cost per pose (information, not a gate)
--------------------------------------------------------------------------------

local report = {}
for _, entry in ipairs({ { 'tween', tl }, { 'path linear', pl }, { 'path catmull', cat }, { 'orbit', ob },
    { 'keys smooth', ks }, { 'dr', dr } }) do
    local d = entry[2]
    local started = os.clock()
    for i = 1, 100000 do M.pose(1, 2, 3, 4, 5, 6, d, T + i) end
    report[#report + 1] = ('%s %.2f'):format(entry[1], (os.clock() - started) * 10)
end
print('scene motion bench (us per pose): ' .. table.concat(report, ', '))

print(('scene motion: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
