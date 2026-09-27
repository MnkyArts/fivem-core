--[[
    core / shared/scene_motion.lua  —  Core.SceneMotion (DESIGN §55.9; internal, both core VMs; pure)

    Motion descriptors are plans evaluated locally from ONE clock (Core.Clock), so the server's movers and
    every client land on the same pose for the same `t` with no steady traffic. Pure Lua: no natives (the
    only clock read is the default `t0` of validate(), and `t = nil` in pose()), no allocation in pose() /
    velocity() / finished() once a path's arc-length table exists. Identical numbers in every VM.

    Motion.validate(desc) -> true, normalized | false, err
    Motion.pose(bx, by, bz, brx, bry, brz, desc, t) -> x, y, z, rx, ry, rz, moving
    Motion.velocity(desc, t [, bx, by, bz]) -> vx, vy, vz          m/s (0 for static / rotation-only)
    Motion.finished(desc, t) -> boolean                             the pose never changes again from t on
    Motion.needsRebase(desc, t) -> boolean                          |Clock.diff(t, t0)| > 2^30 ms (≈ 12.4 days)
    Motion.rebase(desc, t) -> desc'                                 a NEW descriptor, t0 at t, the same future

    Normalized descriptors (what validate() answers, what the server stores and the wire carries; points and
    vectors are `{ x =, y =, z = }`, angles degrees normalised to (-180, 180], times Clock ms, t0 a u32):
      { t = 'tween', t0, d = ms, e = 'linear'|'in'|'out'|'inout', to = { x, y, z, rx?, ry?, rz? }, from? }
            `from` nil = the base pose; a rotation axis missing in `to` keeps the start value. Cubic easing.
      { t = 'path', t0, pts = { p1 … p64 }, sp = m/s | d = ms, loop = 'once'|'loop'|'pingpong',
        curve = 'linear'|'catmull', face = 'fixed'|'path', ph? = ms }
            defaults: loop 'once', curve 'linear', face 'fixed'. Consecutive points closer than 1 mm are merged.
            'loop' CLOSES the path (last point → first point, a first point repeated at the end is dropped) and
            repeats it; 'pingpong' runs start → end → start. `d` is the time of ONE pass (start → end, or one
            lap of a closed path); `sp` gives the same through the arc length. 'catmull' is centripetal
            Catmull-Rom (alpha 0.5; open ends mirror their neighbour), and both curves are walked at constant
            speed through an arc-length table of 16 samples per segment (cached per descriptor, weak keys).
            face 'path' sets rz to the GTA heading of the travel direction (rx, ry stay the base's).
            `ph` (ms, default 0) is a phase offset added to Δt — rebase() writes it for loops and pingpongs.
      { t = 'spin', t0, axis = 'x'|'y'|'z' (default 'z'), dps, a0 = deg }   adds a0 + dps·Δt to the base axis
      { t = 'osc', t0, dir (unit), amp = m, period = ms, phase = deg }  base + dir·amp·sin(2π·Δt/period + phase)
      { t = 'orbit', t0, c, r = m, period = ms, a0 = deg, cw = bool, face = 'fixed'|'path'|'center' }
            position c + r·(-sin h, cos h, 0) with h = a0 ± 360·Δt/period: the angle is a GTA heading around c
            (a0 0 = north of c), counter-clockwise unless cw. face 'path' = along the travel, 'center' = at c.
      { t = 'keys', t0, keys = { { t = ms, x, y, z, rx?, ry?, rz? } … ≤ 128 }, loop = bool, smooth = bool, ph? }
            key times relative to t0, strictly increasing. Before the first key: its pose; after the last: the
            last pose unless loop (period = last.t − first.t; make the last key equal the first for a seamless
            loop). A missing key angle is the base angle. smooth = time-scaled Catmull-Rom (cubic Hermite),
            angles along their shortest arcs. `ph` (ms, default 0) is added to Δt, as for paths.
      { t = 'dr', t0 = sample time, p, v = m/s, yaw? }                 p + v·Δt for Δt ≤ 1 s, then holds;
            rz = yaw when given. `t0` (not `t`: that is the type tag) defaults to Clock.now().
    Before `t0` every motion holds its pose at Δt = 0 with moving = false. Δt comes from Clock.diff, so a
    descriptor is valid within ±24.8 days of its t0 (durations/periods/key times are capped at 2^30 ms).

    Rebase: whoever stores a descriptor (the server's node, a persistent node at load) calls rebase() once
    needsRebase() says so. rebase(desc, t) answers a NEW normalized descriptor whose pose, velocity and
    finished() equal desc's at every time from t on (float precision), with t0 moved to t:
      * periodic motions keep their phase in a field: loop / pingpong paths and looping keys in `ph`, osc in
        `phase`, orbit in `a0`; a spin folds the angle it turned into its `a0` (it has no period);
      * a finished tween, once path or non-looping keys becomes a 1 ms tween that ended at t − 1 on the exact
        end pose (an angle the motion left to the base stays absent); a dr past its 1 s horizon becomes its
        held point with v = 0, sampled at t − 1000;
      * a running tween / once path / keys / dr (each ends within 2^30 ms of t0, so none ever needs it) and a
        plan that has not started (t0 after t: its t0 IS its timing) come back as unchanged copies — a plan
        stamped more than 2^30 ms ahead therefore keeps reporting needsRebase: refuse such plans.

    Heading convention (GTA, fxref GET_HEADING_FROM_VECTOR_2D(dx, dy)): 0° = +Y (north), 90° = −X (west),
    forward(h) = (−sin h, cos h), so the heading of a direction (dx, dy) is atan2(−dx, dy) in degrees.

    Natives: none. Reads Core.Clock (lib) and Core.Config.Scene.Motion.PlanLeadMs (default 200).
]]

local Motion = {}

local Clock = Core.Clock
local diff = Clock.diff

local sqrt, sin, cos, atan, abs, floor = math.sqrt, math.sin, math.cos, math.atan, math.abs, math.floor
local rad, deg, mathType, toInteger = math.rad, math.deg, math.type, math.tointeger
local TAU <const> = 2 * math.pi

local MAX_POINTS <const> = 64
local MAX_KEYS <const> = 128
local MAX_MS <const> = 1073741824        -- 2^30: durations, periods, key times (inside Clock.diff's window)
local COORD <const> = 100000             -- |coordinate| of any point (the server applies the world bounds)
local ANGLE <const> = 1000000            -- |angle| accepted before normalisation
local MAX_SPEED <const> = 10000          -- m/s: path speed, dr velocity components
local MAX_DPS <const> = 36000
local MAX_AMP <const> = 10000
local MAX_RADIUS <const> = 10000
local DR_HORIZON_MS <const> = 1000
local STEPS <const> = 16                 -- arc-length samples per path segment
local DUP2 <const> = 1e-6                -- (1 mm)²: consecutive path points closer than this are merged
local DEFAULT_LEAD_MS <const> = 200

local EASES <const> = { linear = true, ['in'] = true, out = true, inout = true }
local LOOPS <const> = { once = true, loop = true, pingpong = true }
local CURVES <const> = { linear = true, catmull = true }
local PATH_FACES <const> = { fixed = true, path = true }
local ORBIT_FACES <const> = { fixed = true, path = true, center = true }
local AXES <const> = { x = true, y = true, z = true }

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function finite(v, limit)
    return type(v) == 'number' and v == v and abs(v) <= limit
end

--- (-180, 180]; an angle already in range comes back untouched (exact, and validate() stays idempotent).
local function normAngle(a)
    if a > -180 and a <= 180 then return a end
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

--- The signed shortest turn from a to b, in (-180, 180].
local function shortest(a, b)
    return normAngle(b - a)
end

--- GTA heading of a horizontal direction; `fallback` when it has no horizontal length.
local function headingOf(dx, dy, fallback)
    if dx * dx + dy * dy < 1e-12 then return fallback end
    return normAngle(deg(atan(-dx, dy)))
end

--- A point from a vector3, `{ x =, y =, z = }` or `{ x, y, z }` → a new `{ x, y, z }` table, or nil.
local function readPoint(p, limit)
    local tp = type(p)
    if tp ~= 'table' and tp ~= 'vector3' and tp ~= 'vector4' then return nil end
    local x, y, z = p.x, p.y, p.z
    if x == nil and tp == 'table' then x, y, z = p[1], p[2], p[3] end
    limit = limit or COORD
    if not (finite(x, limit) and finite(y, limit) and finite(z, limit)) then return nil end
    return { x = x, y = y, z = z }
end

--- A pose with optional angles: named (`x, y, z, rx, ry, rz`) or positional from index i0 + 1; nil when bad.
local function readPose(p, i0)
    local tp = type(p)
    if tp == 'vector3' or tp == 'vector4' then return readPoint(p) end
    if tp ~= 'table' then return nil end
    local x, y, z, rx, ry, rz
    if p.x ~= nil then
        x, y, z, rx, ry, rz = p.x, p.y, p.z, p.rx, p.ry, p.rz
    else
        x, y, z, rx, ry, rz = p[i0 + 1], p[i0 + 2], p[i0 + 3], p[i0 + 4], p[i0 + 5], p[i0 + 6]
    end
    if not (finite(x, COORD) and finite(y, COORD) and finite(z, COORD)) then return nil end
    local out = { x = x, y = y, z = z }
    if rx ~= nil then if not finite(rx, ANGLE) then return nil end out.rx = normAngle(rx) end
    if ry ~= nil then if not finite(ry, ANGLE) then return nil end out.ry = normAngle(ry) end
    if rz ~= nil then if not finite(rz, ANGLE) then return nil end out.rz = normAngle(rz) end
    return out
end

--- n for a proper list 1..n (no holes, no other keys — `#` alone is unreliable with holes), else nil.
local function listLength(t)
    if type(t) ~= 'table' then return nil end
    local n, count = #t, 0
    for k in pairs(t) do
        if mathType(k) ~= 'integer' or k < 1 or k > n then return nil end
        count = count + 1
    end
    if count ~= n then return nil end
    return n
end

local function planLeadMs()
    local cfg = Core.Config
    local scene = type(cfg) == 'table' and cfg.Scene
    local motion = type(scene) == 'table' and scene.Motion
    local lead = type(motion) == 'table' and motion.PlanLeadMs
    if finite(lead, MAX_MS) and lead >= 0 then return lead end
    return DEFAULT_LEAD_MS
end

--------------------------------------------------------------------------------
-- paths: control points, centripetal Catmull-Rom, the arc-length table
--------------------------------------------------------------------------------

local luts = setmetatable({}, { __mode = 'k' })   -- normalized path descriptor → its table

--- One axis of a centripetal Catmull-Rom segment (Barry–Goldman pyramid, knots 0 < T1 < T2 < T3) at knot
--- parameter u ∈ [T1, T2]: the value and its derivative d/du.
local function crAxis(a0, a1, a2, a3, T1, T2, T3, u)
    local A1 = ((T1 - u) * a0 + u * a1) / T1
    local A2 = ((T2 - u) * a1 + (u - T1) * a2) / (T2 - T1)
    local A3 = ((T3 - u) * a2 + (u - T2) * a3) / (T3 - T2)
    local B1 = ((T2 - u) * A1 + u * A2) / T2
    local B2 = ((T3 - u) * A2 + (u - T1) * A3) / (T3 - T1)
    local dA1 = (a1 - a0) / T1
    local dA2 = (a2 - a1) / (T2 - T1)
    local dA3 = (a3 - a2) / (T3 - T2)
    local dB1 = (A2 - A1 + (T2 - u) * dA1 + u * dA2) / T2
    local dB2 = (A3 - A2 + (T3 - u) * dA2 + (u - T1) * dA3) / (T3 - T1)
    local C = ((T2 - u) * B1 + (u - T1) * B2) / (T2 - T1)
    local dC = (B2 - B1 + (T2 - u) * dB1 + (u - T1) * dB2) / (T2 - T1)
    return C, dC
end

--- Point and derivative d/ds of segment `seg` (points seg → seg + 1 of the extended arrays) at s ∈ [0, 1].
local function evalSeg(lut, seg, s)
    local ex, ey, ez = lut.ex, lut.ey, lut.ez
    local i2 = seg + 1
    if not lut.catmull then
        local x1, y1, z1 = ex[seg], ey[seg], ez[seg]
        local dx, dy, dz = ex[i2] - x1, ey[i2] - y1, ez[i2] - z1
        return x1 + dx * s, y1 + dy * s, z1 + dz * s, dx, dy, dz
    end
    local T1, T2, T3 = lut.k1[seg], lut.k2[seg], lut.k3[seg]
    local u = T1 + s * (T2 - T1)
    local i0, i3 = seg - 1, seg + 2
    local x, dx = crAxis(ex[i0], ex[seg], ex[i2], ex[i3], T1, T2, T3, u)
    local y, dy = crAxis(ey[i0], ey[seg], ey[i2], ey[i3], T1, T2, T3, u)
    local z, dz = crAxis(ez[i0], ez[seg], ez[i2], ez[i3], T1, T2, T3, u)
    local scale = T2 - T1
    return x, y, z, dx * scale, dy * scale, dz * scale
end

--- |Pj − Pi|^0.5 of the extended arrays: the centripetal knot interval.
local function knot(lut, i, j)
    local dx, dy, dz = lut.ex[j] - lut.ex[i], lut.ey[j] - lut.ey[i], lut.ez[j] - lut.ez[i]
    return sqrt(sqrt(dx * dx + dy * dy + dz * dz))
end

--- Extended control points (index 0 .. n + 2: wrap-around neighbours when closed, mirrored ends when open),
--- centripetal knots per segment, and per sample interval (STEPS per segment) the cumulative arc length
--- (Simpson's rule over the analytic |dC/ds|) plus that speed at the interval's start, middle and end.
local function buildLut(desc)
    local pts = desc.pts
    local n = #pts
    local closed = desc.loop == 'loop'
    local ex, ey, ez = {}, {}, {}
    for i = 1, n do
        local p = pts[i]
        ex[i], ey[i], ez[i] = p.x, p.y, p.z
    end
    if closed then
        ex[0], ey[0], ez[0] = ex[n], ey[n], ez[n]
        ex[n + 1], ey[n + 1], ez[n + 1] = ex[1], ey[1], ez[1]
        ex[n + 2], ey[n + 2], ez[n + 2] = ex[2], ey[2], ez[2]
    else
        ex[0], ey[0], ez[0] = 2 * ex[1] - ex[2], 2 * ey[1] - ey[2], 2 * ez[1] - ez[2]
        ex[n + 1], ey[n + 1], ez[n + 1] = 2 * ex[n] - ex[n - 1], 2 * ey[n] - ey[n - 1], 2 * ez[n] - ez[n - 1]
    end
    local nseg = closed and n or n - 1
    local lut = { ex = ex, ey = ey, ez = ez, nseg = nseg, catmull = desc.curve == 'catmull',
        k1 = {}, k2 = {}, k3 = {}, cum = { 0 }, va = {}, vm = {}, vb = {}, total = 0, samples = 1 }
    if lut.catmull then
        for seg = 1, nseg do
            local d01, d12, d23 = knot(lut, seg - 1, seg), knot(lut, seg, seg + 1), knot(lut, seg + 1, seg + 2)
            lut.k1[seg], lut.k2[seg], lut.k3[seg] = d01, d01 + d12, d01 + d12 + d23
        end
    end
    local cum, va, vm, vb, total, j = lut.cum, lut.va, lut.vm, lut.vb, 0, 1
    local h = 1 / STEPS
    for seg = 1, nseg do
        local _, _, _, dx, dy, dz = evalSeg(lut, seg, 0)
        local a = sqrt(dx * dx + dy * dy + dz * dz)
        for k = 1, STEPS do
            local _, _, _, mx, my, mz = evalSeg(lut, seg, (k - 0.5) * h)
            local _, _, _, bx, by, bz = evalSeg(lut, seg, k * h)
            local m, b = sqrt(mx * mx + my * my + mz * mz), sqrt(bx * bx + by * by + bz * bz)
            total = total + h * (a + 4 * m + b) / 6
            va[j], vm[j], vb[j] = a, m, b             -- interval j runs from cum[j] to cum[j + 1]
            j = j + 1
            cum[j] = total
            a = b
        end
    end
    lut.total, lut.samples = total, j
    return lut
end

local function lutOf(desc)
    local lut = luts[desc]
    if lut == nil then
        lut = buildLut(desc)
        luts[desc] = lut
    end
    return lut
end

--- Arc length → segment, s. Binary search for the sample interval; inside it the speed |dC/ds| is the
--- quadratic through its three stored values (the model Simpson's rule integrated), so the distance is a cubic
--- in s, inverted by Newton from the linear guess. Constant speed on catmull curves, one curve evaluation per
--- pose (the caller's), no allocation.
local function locate(lut, dist)
    if dist <= 0 then return 1, 0 end
    if dist >= lut.total then return lut.nseg, 1 end
    local cum, lo, hi = lut.cum, 1, lut.samples
    while hi - lo > 1 do
        local mid = (lo + hi) // 2
        if cum[mid] <= dist then lo = mid else hi = mid end
    end
    local x, len = dist - cum[lo], cum[hi] - cum[lo]
    local f = 0
    if len > 0 then
        local a, m, b = lut.va[lo], lut.vm[lo], lut.vb[lo]
        local c1, c2 = 4 * m - 3 * a - b, 2 * (a - 2 * m + b)       -- speed(τ) = a + c1·τ + c2·τ²
        local h = 1 / STEPS
        f = x / len
        for _ = 1, 3 do
            local speed = a + (c1 + c2 * f) * f
            if speed <= 0 then break end
            f = f - (h * f * (a + f * (c1 / 2 + f * c2 / 3)) - x) / (h * speed)
            if f < 0 then f = 0 elseif f > 1 then f = 1 end
        end
    end
    local g = lo - 1
    return g // STEPS + 1, (g % STEPS + f) / STEPS
end

--- One pass (ms): `d`, or the arc length at `sp`.
local function passMs(desc, lut)
    return desc.d or lut.total / desc.sp * 1000
end

--- Where on the path at Δt (+ the phase offset `ph`): arc length, direction (+1 / −1), moving. Before t0 the
--- pose of Δt = 0 holds.
local function pathAt(desc, lut, dt)
    local moving = dt >= 0
    if not moving then dt = 0 end
    dt = dt + (desc.ph or 0)
    local pass, total = passMs(desc, lut), lut.total
    local loop = desc.loop
    if loop == 'loop' then return total * ((dt % pass) / pass), 1, moving end
    if loop == 'pingpong' then
        local phase = dt % (2 * pass)
        if phase < pass then return total * (phase / pass), 1, moving end
        return total * ((2 * pass - phase) / pass), -1, moving
    end
    if dt >= pass then return total, 1, false end
    return total * (dt / pass), 1, moving
end

--------------------------------------------------------------------------------
-- validate: bounds, defaults, normalisation (never mutates the input)
--------------------------------------------------------------------------------

local function dist2(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

local VALIDATE = {}

--- The optional phase offset `ph` (ms, 0 .. 2^30) of paths and keys; kept only when > 0.
local function readPhase(d, out)
    local ph = d.ph
    if ph == nil then return nil end
    if not finite(ph, MAX_MS) or ph < 0 then return 'bad_phase' end
    if ph > 0 then out.ph = ph end
end

function VALIDATE.tween(d, out)
    local dur = d.d
    if not finite(dur, MAX_MS) or dur <= 0 then return 'bad_duration' end
    local e = d.e == nil and 'linear' or d.e
    if not EASES[e] then return 'bad_ease' end
    local to = readPose(d.to, 0)
    if not to then return 'bad_to' end
    out.d, out.e, out.to = dur, e, to
    if d.from ~= nil then
        local from = readPose(d.from, 0)
        if not from then return 'bad_from' end
        out.from = from
    end
end

function VALIDATE.path(d, out)
    local n = listLength(d.pts)
    if not n then return 'bad_points' end
    if n > MAX_POINTS then return 'too_many_points' end
    local loop = d.loop == nil and 'once' or d.loop
    if not LOOPS[loop] then return 'bad_loop' end
    local curve = d.curve == nil and 'linear' or d.curve
    if not CURVES[curve] then return 'bad_curve' end
    local face = d.face == nil and 'fixed' or d.face
    if not PATH_FACES[face] then return 'bad_face' end
    local pts, last = {}, nil
    for i = 1, n do
        local p = readPoint(d.pts[i])
        if not p then return 'bad_point' end
        if last == nil or dist2(p, last) > DUP2 then
            pts[#pts + 1] = p
            last = p
        end
    end
    if loop == 'loop' and #pts > 1 and dist2(pts[#pts], pts[1]) <= DUP2 then pts[#pts] = nil end
    if #pts < 2 then return 'bad_points' end
    local sp, dur = d.sp, d.d
    if (sp == nil) == (dur == nil) then return 'bad_timing' end
    if sp ~= nil then
        if not finite(sp, MAX_SPEED) or sp <= 0 then return 'bad_speed' end
    elseif not finite(dur, MAX_MS) or dur <= 0 then
        return 'bad_duration'
    end
    out.pts, out.loop, out.curve, out.face, out.sp, out.d = pts, loop, curve, face, sp, dur
    local phaseErr = readPhase(d, out)
    if phaseErr then return phaseErr end
    local pass = passMs(out, lutOf(out))   -- builds (and caches) the arc-length table of `out`
    if not (pass > 0 and pass <= MAX_MS) then return 'bad_duration' end
end

function VALIDATE.spin(d, out)
    local axis = d.axis == nil and 'z' or d.axis
    if not AXES[axis] then return 'bad_axis' end
    if not finite(d.dps, MAX_DPS) then return 'bad_dps' end
    local a0 = d.a0 == nil and 0 or d.a0
    if not finite(a0, ANGLE) then return 'bad_angle' end
    out.axis, out.dps, out.a0 = axis, d.dps, normAngle(a0)
end

function VALIDATE.osc(d, out)
    local dir = readPoint(d.dir)
    if not dir then return 'bad_dir' end
    local len = sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
    if len < 1e-9 then return 'bad_dir' end
    if abs(len - 1) > 1e-12 then dir.x, dir.y, dir.z = dir.x / len, dir.y / len, dir.z / len end
    if not finite(d.amp, MAX_AMP) then return 'bad_amp' end
    local period = d.period
    if not finite(period, MAX_MS) or period <= 0 then return 'bad_period' end
    local phase = d.phase == nil and 0 or d.phase
    if not finite(phase, ANGLE) then return 'bad_phase' end
    out.dir, out.amp, out.period, out.phase = dir, d.amp, period, normAngle(phase)
end

function VALIDATE.orbit(d, out)
    local c = readPoint(d.c)
    if not c then return 'bad_center' end
    local r = d.r
    if not finite(r, MAX_RADIUS) or r <= 0 then return 'bad_radius' end
    local period = d.period
    if not finite(period, MAX_MS) or period <= 0 then return 'bad_period' end
    local a0 = d.a0 == nil and 0 or d.a0
    if not finite(a0, ANGLE) then return 'bad_angle' end
    local face = d.face == nil and 'fixed' or d.face
    if not ORBIT_FACES[face] then return 'bad_face' end
    out.c, out.r, out.period, out.a0, out.cw, out.face = c, r, period, normAngle(a0), d.cw == true, face
end

function VALIDATE.keys(d, out)
    local n = listLength(d.keys)
    if not n or n < 2 then return 'bad_keys' end
    if n > MAX_KEYS then return 'too_many_keys' end
    local keys, prev = {}, nil
    for i = 1, n do
        local k = d.keys[i]
        if type(k) ~= 'table' then return 'bad_key' end
        local kt = k.t
        if kt == nil then kt = k[1] end                     -- positional: { t, x, y, z, rx?, ry?, rz? }
        if not finite(kt, MAX_MS) or kt < 0 or (prev ~= nil and kt <= prev) then return 'bad_key_time' end
        local pose = readPose(k, 1)
        if not pose then return 'bad_key' end
        pose.t = kt
        keys[i] = pose
        prev = kt
    end
    out.keys, out.loop, out.smooth = keys, d.loop == true, d.smooth == true
    return readPhase(d, out)
end

function VALIDATE.dr(d, out)
    local p = readPoint(d.p)
    if not p then return 'bad_p' end
    local v = readPoint(d.v, MAX_SPEED)
    if not v then return 'bad_v' end
    out.p, out.v = p, v
    if d.yaw ~= nil then
        if not finite(d.yaw, ANGLE) then return 'bad_yaw' end
        out.yaw = normAngle(d.yaw)
    end
end

--- -> true, normalized (a new table) | false, err ('bad_desc' | 'bad_type' | 'bad_t0' | a per-type code)
function Motion.validate(desc)
    if type(desc) ~= 'table' then return false, 'bad_desc' end
    local kind = desc.t
    local check = type(kind) == 'string' and VALIDATE[kind] or nil
    if not check then return false, 'bad_type' end
    local t0 = desc.t0
    if t0 == nil then
        t0 = kind == 'dr' and Clock.now() or Clock.at(planLeadMs())
    else
        t0 = type(t0) == 'number' and toInteger(t0) or nil
        if t0 == nil then return false, 'bad_t0' end
        t0 = t0 & 0xFFFFFFFF
    end
    local out = { t = kind, t0 = t0 }
    local err = check(desc, out)
    if err then return false, err end
    return true, out
end

--------------------------------------------------------------------------------
-- evaluation (no allocation)
--------------------------------------------------------------------------------

--- Cubic easing: value and derivative d/du.
local function ease(e, u)
    if e == 'in' then return u * u * u, 3 * u * u end
    if e == 'out' then
        local v = 1 - u
        return 1 - v * v * v, 3 * v * v
    end
    if e == 'inout' then
        if u < 0.5 then return 4 * u * u * u, 12 * u * u end
        local v = 2 - 2 * u
        return 1 - v * v * v / 2, 3 * v * v
    end
    return u, 1
end

--- Key time and moving flag of a keys descriptor at Δt (+ `ph`). Before t0 the pose of Δt = 0 holds.
local function keyTime(d, dt)
    local moving = dt >= 0
    if not moving then dt = 0 end
    dt = dt + (d.ph or 0)
    local keys = d.keys
    local first, last = keys[1].t, keys[#keys].t
    if dt < first then return first, false end
    if d.loop then return first + (dt - first) % (last - first), moving end
    if dt >= last then return last, false end
    return dt, moving
end

--- One channel of keys segment i at u: value and slope per ms. Linear, or cubic Hermite with time-scaled
--- Catmull-Rom tangents (p / q = the neighbour key indexes or nil, pt / qt their times). Angular channels
--- fall back to `base` for a missing key angle and follow the shortest arcs.
local function keysChannel(keys, f, base, i, u, smooth, p, pt, q, qt, angular)
    local k1, k2 = keys[i], keys[i + 1]
    local t1, t2 = k1.t, k2.t
    local v1, v2 = k1[f] or base, k2[f] or base
    if angular then v2 = v1 + shortest(v1, v2) end
    local h = t2 - t1
    if not smooth then return v1 * (1 - u) + v2 * u, (v2 - v1) / h end
    local m1, m2 = (v2 - v1) / h, (v2 - v1) / h
    if p then
        local v0 = keys[p][f] or base
        if angular then v0 = v1 - shortest(v0, v1) end
        m1 = (v2 - v0) / (t2 - pt)
    end
    if q then
        local v3 = keys[q][f] or base
        if angular then v3 = v2 + shortest(k2[f] or base, v3) end
        m2 = (v3 - v1) / (qt - t1)
    end
    local u2 = u * u
    local u3 = u2 * u
    local value = (2 * u3 - 3 * u2 + 1) * v1 + (u3 - 2 * u2 + u) * h * m1 + (3 * u2 - 2 * u3) * v2
        + (u3 - u2) * h * m2
    local slope = ((6 * u2 - 6 * u) * v1 + (3 * u2 - 4 * u + 1) * h * m1 + (6 * u - 6 * u2) * v2
        + (3 * u2 - 2 * u) * h * m2) / h
    return value, slope
end

--- The segment of a keys descriptor at key time kt, its u and the smooth neighbours.
local function keysLocate(d, kt)
    local keys = d.keys
    local n = #keys
    local lo, hi = 1, n
    while hi - lo > 1 do
        local mid = (lo + hi) // 2
        if keys[mid].t <= kt then lo = mid else hi = mid end
    end
    local t1, t2 = keys[lo].t, keys[lo + 1].t
    local u = (kt - t1) / (t2 - t1)
    if u > 1 then u = 1 end
    if not d.smooth then return lo, u end
    local span = keys[n].t - keys[1].t
    local wrap = d.loop and n >= 3
    local p, pt, q, qt
    if lo > 1 then p, pt = lo - 1, keys[lo - 1].t
    elseif wrap then p, pt = n - 1, keys[n - 1].t - span end
    if lo + 1 < n then q, qt = lo + 2, keys[lo + 2].t
    elseif wrap then q, qt = 2, keys[2].t + span end
    return lo, u, p, pt, q, qt
end

local POSE = {}

function POSE.tween(bx, by, bz, brx, bry, brz, d, dt)
    local from, to = d.from, d.to
    local fx, fy, fz, frx, fry, frz = bx, by, bz, brx, bry, brz
    if from then
        fx, fy, fz = from.x, from.y, from.z
        frx, fry, frz = from.rx or brx, from.ry or bry, from.rz or brz
    end
    if dt >= d.d then                                           -- ended: exactly the target
        return to.x, to.y, to.z, to.rx or frx, to.ry or fry, to.rz or frz, false
    end
    local moving = dt >= 0
    local k = moving and ease(d.e, dt / d.d) or 0
    local rx, ry, rz = frx, fry, frz
    if to.rx then rx = normAngle(frx + shortest(frx, to.rx) * k) end
    if to.ry then ry = normAngle(fry + shortest(fry, to.ry) * k) end
    if to.rz then rz = normAngle(frz + shortest(frz, to.rz) * k) end
    local j = 1 - k
    return fx * j + to.x * k, fy * j + to.y * k, fz * j + to.z * k, rx, ry, rz, moving
end

function POSE.path(_, _, _, brx, bry, brz, d, dt)
    local lut = luts[d] or lutOf(d)
    local dist, sign, moving = pathAt(d, lut, dt)
    local x, y, z, dx, dy = evalSeg(lut, locate(lut, dist))
    local rz = brz
    if d.face == 'path' then rz = headingOf(dx * sign, dy * sign, brz) end
    return x, y, z, brx, bry, rz, moving
end

function POSE.spin(bx, by, bz, brx, bry, brz, d, dt)
    local a = d.a0 or 0
    if dt > 0 then a = a + (d.dps * dt) % 360000 / 1000 end   -- exact for integer dps: no drift over days
    local moving = dt >= 0 and d.dps ~= 0
    local axis = d.axis
    if axis == 'x' then return bx, by, bz, normAngle(brx + a), bry, brz, moving end
    if axis == 'y' then return bx, by, bz, brx, normAngle(bry + a), brz, moving end
    return bx, by, bz, brx, bry, normAngle(brz + a), moving
end

function POSE.osc(bx, by, bz, brx, bry, brz, d, dt)
    local moving = dt >= 0
    if not moving then dt = 0 end
    local period = d.period
    local off = d.amp * sin(TAU * ((dt % period) / period) + rad(d.phase))
    local dir = d.dir
    return bx + dir.x * off, by + dir.y * off, bz + dir.z * off, brx, bry, brz, moving
end

function POSE.orbit(_, _, _, brx, bry, brz, d, dt)
    local moving = dt >= 0
    if not moving then dt = 0 end
    local period = d.period
    local h = d.a0 + (d.cw and -360 or 360) * ((dt % period) / period)
    local hr, c, r = rad(h), d.c, d.r
    local rz = brz
    if d.face == 'path' then rz = normAngle(h + (d.cw and -90 or 90))
    elseif d.face == 'center' then rz = normAngle(h + 180) end
    return c.x - r * sin(hr), c.y + r * cos(hr), c.z, brx, bry, rz, moving
end

function POSE.keys(_, _, _, brx, bry, brz, d, dt)
    local keys, smooth = d.keys, d.smooth
    local kt, moving = keyTime(d, dt)
    local i, u, p, pt, q, qt = keysLocate(d, kt)
    local x = keysChannel(keys, 'x', 0, i, u, smooth, p, pt, q, qt, false)
    local y = keysChannel(keys, 'y', 0, i, u, smooth, p, pt, q, qt, false)
    local z = keysChannel(keys, 'z', 0, i, u, smooth, p, pt, q, qt, false)
    local rx = keysChannel(keys, 'rx', brx, i, u, smooth, p, pt, q, qt, true)
    local ry = keysChannel(keys, 'ry', bry, i, u, smooth, p, pt, q, qt, true)
    local rz = keysChannel(keys, 'rz', brz, i, u, smooth, p, pt, q, qt, true)
    return x, y, z, normAngle(rx), normAngle(ry), normAngle(rz), moving
end

function POSE.dr(_, _, _, brx, bry, brz, d, dt)
    if dt < 0 then dt = 0 end
    local p, v = d.p, d.v
    local moving = dt < DR_HORIZON_MS and (v.x ~= 0 or v.y ~= 0 or v.z ~= 0)
    if dt > DR_HORIZON_MS then dt = DR_HORIZON_MS end
    local s = dt / 1000
    return p.x + v.x * s, p.y + v.y * s, p.z + v.z * s, brx, bry, d.yaw or brz, moving
end

--- The pose at Clock time t (nil = now) of a node whose base pose is (bx .. brz). desc nil → the base pose.
function Motion.pose(bx, by, bz, brx, bry, brz, desc, t)
    local fn = type(desc) == 'table' and POSE[desc.t] or nil
    if not fn then return bx, by, bz, brx, bry, brz, false end
    return fn(bx, by, bz, brx, bry, brz, desc, diff(t or Clock.now(), desc.t0 or 0))
end

--- Linear velocity (m/s) at Clock time t. A tween without `from` needs the base position (bx, by, bz) —
--- without it that tween reports 0. Spins (rotation only), ended and not-yet-started motions report 0.
function Motion.velocity(desc, t, bx, by, bz)
    local kind = type(desc) == 'table' and desc.t or nil
    if kind == nil then return 0, 0, 0 end
    local dt = diff(t or Clock.now(), desc.t0 or 0)
    if kind == 'dr' then
        if dt >= DR_HORIZON_MS then return 0, 0, 0 end
        local v = desc.v
        return v.x, v.y, v.z
    end
    if dt < 0 then return 0, 0, 0 end
    if kind == 'tween' then
        if dt >= desc.d then return 0, 0, 0 end
        local from, to = desc.from, desc.to
        local fx, fy, fz = bx, by, bz
        if from then fx, fy, fz = from.x, from.y, from.z end
        if fx == nil then return 0, 0, 0 end
        local _, slope = ease(desc.e, dt / desc.d)
        local k = slope / desc.d * 1000
        return (to.x - fx) * k, (to.y - fy) * k, (to.z - fz) * k
    elseif kind == 'path' then
        local lut = luts[desc] or lutOf(desc)
        local dist, sign, moving = pathAt(desc, lut, dt)
        if not moving then return 0, 0, 0 end
        local _, _, _, dx, dy, dz = evalSeg(lut, locate(lut, dist))
        local len = sqrt(dx * dx + dy * dy + dz * dz)
        if len < 1e-12 then return 0, 0, 0 end
        local k = sign * lut.total / passMs(desc, lut) * 1000 / len
        return dx * k, dy * k, dz * k
    elseif kind == 'osc' then
        local period, dir = desc.period, desc.dir
        local k = desc.amp * cos(TAU * ((dt % period) / period) + rad(desc.phase)) * TAU / period * 1000
        return dir.x * k, dir.y * k, dir.z * k
    elseif kind == 'orbit' then
        local period = desc.period
        local sign = desc.cw and -1 or 1
        local h = rad(desc.a0 + sign * 360 * ((dt % period) / period))
        local k = sign * desc.r * TAU / period * 1000
        return -cos(h) * k, -sin(h) * k, 0
    elseif kind == 'keys' then
        local kt, moving = keyTime(desc, dt)
        if not moving then return 0, 0, 0 end
        local keys, smooth = desc.keys, desc.smooth
        local i, u, p, pt, q, qt = keysLocate(desc, kt)
        local _, vx = keysChannel(keys, 'x', 0, i, u, smooth, p, pt, q, qt, false)
        local _, vy = keysChannel(keys, 'y', 0, i, u, smooth, p, pt, q, qt, false)
        local _, vz = keysChannel(keys, 'z', 0, i, u, smooth, p, pt, q, qt, false)
        return vx * 1000, vy * 1000, vz * 1000
    end
    return 0, 0, 0
end

--- True when the pose can no longer change from t on (an ended once-motion, a held dr, nil, an unknown type).
function Motion.finished(desc, t)
    local kind = type(desc) == 'table' and desc.t or nil
    if kind == nil then return true end
    local dt = diff(t or Clock.now(), desc.t0 or 0)
    if kind == 'tween' then return dt >= desc.d end
    if kind == 'path' then
        return desc.loop == 'once' and dt >= 0 and dt + (desc.ph or 0) >= passMs(desc, luts[desc] or lutOf(desc))
    end
    if kind == 'keys' then return not desc.loop and dt >= 0 and dt + (desc.ph or 0) >= desc.keys[#desc.keys].t end
    if kind == 'dr' then return dt >= DR_HORIZON_MS end
    if kind == 'spin' then return desc.dps == 0 end
    if kind == 'osc' then return desc.amp == 0 end
    return kind ~= 'orbit'
end

--------------------------------------------------------------------------------
-- rebase: keep a stored descriptor inside Clock.diff's ±2^31 ms window (see the file header)
--------------------------------------------------------------------------------

local function clone(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, item in pairs(v) do out[k] = clone(item) end
    return out
end

--- The finished form: a 1 ms linear tween that ended at t − 1 on the end pose (nil angles keep the base).
local function ended(t, x, y, z, rx, ry, rz)
    return { t = 'tween', t0 = Clock.add(t, -1), d = 1, e = 'linear',
        to = { x = x, y = y, z = z, rx = rx, ry = ry, rz = rz } }
end

--- Per type: (desc, its copy, t, Δt ≥ 0) -> the rebased descriptor.
local REBASE = {}

function REBASE.tween(d, copy, t, dt)
    if dt < d.d then return copy end                                  -- still running
    local to, from = d.to, d.from
    return ended(t, to.x, to.y, to.z, to.rx or (from and from.rx), to.ry or (from and from.ry),
        to.rz or (from and from.rz))
end

function REBASE.path(d, copy, t, dt)
    local lut = luts[d] or lutOf(d)
    local pass = passMs(d, lut)
    local eff = dt + (d.ph or 0)
    if d.loop == 'once' then
        if eff < pass then return copy end                            -- still running
        local x, y, z, dx, dy = evalSeg(lut, lut.nseg, 1)             -- exactly where pose() ends
        return ended(t, x, y, z, nil, nil, d.face == 'path' and headingOf(dx, dy, nil) or nil)
    end
    local ph = eff % (d.loop == 'pingpong' and 2 * pass or pass)
    copy.t0, copy.ph = t, ph > 0 and ph or nil
    luts[copy] = lut                                                  -- the same points: the same table
    return copy
end

function REBASE.keys(d, copy, t, dt)
    local keys = d.keys
    local first, last = keys[1].t, keys[#keys].t
    local eff = dt + (d.ph or 0)
    if not d.loop then
        if eff < last then return copy end                            -- still running
        local k = keys[#keys]
        return ended(t, k.x, k.y, k.z, k.rx, k.ry, k.rz)
    end
    if eff < first then return copy end                               -- before its first key
    local ph = first + (eff - first) % (last - first)
    copy.t0, copy.ph = t, ph > 0 and ph or nil
    return copy
end

function REBASE.spin(d, copy, t, dt)
    copy.t0, copy.a0 = t, normAngle((d.a0 or 0) + (d.dps * dt) % 360000 / 1000)
    return copy
end

function REBASE.osc(d, copy, t, dt)
    local period = d.period
    copy.t0, copy.phase = t, normAngle(d.phase + 360 * ((dt % period) / period))
    return copy
end

function REBASE.orbit(d, copy, t, dt)
    local period = d.period
    copy.t0, copy.a0 = t, normAngle(d.a0 + (d.cw and -360 or 360) * ((dt % period) / period))
    return copy
end

function REBASE.dr(d, copy, t, dt)
    if dt < DR_HORIZON_MS then return copy end                        -- still extrapolating
    local p, v = d.p, d.v
    copy.t0 = Clock.add(t, -DR_HORIZON_MS)
    copy.p = { x = p.x + v.x, y = p.y + v.y, z = p.z + v.z }          -- = p + v · (horizon / 1 s)
    copy.v = { x = 0, y = 0, z = 0 }
    return copy
end

--- True when t0 is more than 2^30 ms (≈ 12.4 days) away from t (nil = now): rebase before Clock.diff wraps.
function Motion.needsRebase(desc, t)
    if type(desc) ~= 'table' or type(desc.t0) ~= 'number' then return false end
    return abs(diff(t or Clock.now(), desc.t0)) > MAX_MS
end

--- A NEW normalized descriptor equal to desc from t (nil = now) on, with t0 at t (see the file header).
--- Never mutates desc; nil for a non-table; an unknown type comes back as a copy.
function Motion.rebase(desc, t)
    if type(desc) ~= 'table' then return nil end
    t = Clock.add(t or Clock.now(), 0)
    local copy = clone(desc)
    local fn = REBASE[desc.t]
    if not fn then return copy end
    local dt = diff(t, desc.t0 or 0)
    if dt < 0 then return copy end                                    -- not started: its t0 is its timing
    return fn(desc, copy, t, dt)
end

Core.SceneMotion = Motion
