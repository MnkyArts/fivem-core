-- Offline pure geometry checks, including hostile registration inputs and zone edges.
local here = (arg[0]:match('^(.*)/') or '.')
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local env = stubs.newEnv('client', 'core')
local Geometry = {}
assert(loadfile(here .. '/../lib/geometry/shared.lua', 't', env))(Geometry)
local v = stubs.vector3
local passed = 0
local function eq(actual, expected, label)
    assert(actual == expected, label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    passed = passed + 1
end
local function rejects(def, label)
    local shape, reason = Geometry.normalize(def)
    eq(shape, nil, label)
    eq(type(reason), 'string', label .. ' reason')
end
local function norm(def)
    local shape, reason = Geometry.normalize(def)
    assert(shape, reason)
    passed = passed + 1
    return shape
end
local function poly(points, minZ, maxZ)
    return { type = 'polygon', points = points, minZ = minZ or -2, maxZ = maxZ or 2 }
end

local sphere = norm({ type = 'sphere', coords = v(0, 0, 0), radius = 10 })
eq(Geometry.contains(sphere, v(0, 0, 0)), true, 'sphere centre')
eq(Geometry.contains(sphere, v(10, 0, 0)), true, 'sphere edge')
eq(Geometry.contains(sphere, v(0, 0, -10)), true, 'sphere bottom')
eq(Geometry.contains(sphere, v(0, 0, 10.001)), false, 'sphere height miss')
eq(Geometry.contains(sphere, v(8, 8, 0)), false, 'sphere broadphase corner miss')
eq(sphere.bounds.minX, -10, 'sphere bound')
eq(sphere.maxZ, 10, 'sphere height')
local box = norm({ type = 'box', coords = { 10, 20, 30 }, size = { x = 8, y = 2, z = 4 }, rotation = 90 })
eq(Geometry.contains(box, v(10, 24, 32)), true, 'rotated box corner')
eq(Geometry.contains(box, v(11, 20, 30)), true, 'rotated box narrow edge')
eq(Geometry.contains(box, v(12, 20, 30)), false, 'rotated box narrow outside')
eq(Geometry.contains(box, v(10, 24.001, 30)), false, 'rotated box long outside')
eq(Geometry.contains(box, v(10, 20, 32.001)), false, 'rotated box above')
eq(math.abs(box.bounds.maxX - 11) < 1e-6, true, 'rotated broadphase x')
eq(math.abs(box.bounds.maxY - 24) < 1e-6, true, 'rotated broadphase y')
local straight = norm({ type = 'box', coords = v(0, 0, 0), size = v(4, 2, 2) })
eq(straight.rotation, 0, 'default rotation')
eq(Geometry.contains(straight, v(2, 1, 1)), true, 'box exact corner')
local rotated = norm({ type = 'box', coords = v(0, 0, 0), size = v(4, 2, 2), rotation = -315 })
eq(rotated.rotation, 45, 'rotation normalization')
eq(Geometry.contains(rotated, v(math.sqrt(2), math.sqrt(2), 0)), true, '45-degree edge')
eq(Geometry.contains(rotated, v(2, 0, 0)), false, '45-degree outside')

local squarePoints = { v(-4, -4, 0), v(4, -4, 0), v(4, 4, 0), v(-4, 4, 0) }
local square = norm(poly(squarePoints))
eq(Geometry.contains(square, v(0, 0, 0)), true, 'polygon interior')
eq(Geometry.contains(square, v(4, 0, 2)), true, 'polygon side at ceiling')
eq(Geometry.contains(square, v(-4, -4, -2)), true, 'polygon vertex at floor')
eq(Geometry.contains(square, v(4.001, 0, 0)), false, 'polygon outside')
eq(Geometry.contains(square, v(0, 0, 2.001)), false, 'polygon above')
eq(Geometry.contains(square, v(0, 0, -2.001)), false, 'polygon below')
eq(square.bounds.minX, -4, 'polygon bounds')
eq(square.radius >= 6, true, 'polygon radius covers 3D corners')
squarePoints[1] = v(999, 999, 0)
eq(square.points[1].x, -4, 'detached polygon source')
local reverse = norm(poly({ v(-4, 4, 0), v(4, 4, 0), v(4, -4, 0), v(-4, -4, 0) }))
eq(Geometry.contains(reverse, v(0, 0, 0)), true, 'clockwise polygon')
local concave = norm(poly({ v(0, 0, 0), v(4, 0, 0), v(4, 1, 0), v(1, 1, 0), v(1, 4, 0), v(0, 4, 0) }))
eq(Geometry.contains(concave, v(.5, 3, 0)), true, 'concave arm')
eq(Geometry.contains(concave, v(3, .5, 0)), true, 'concave base')
eq(Geometry.contains(concave, v(3, 3, 0)), false, 'concave cutout')
eq(Geometry.contains(concave, v(1, 1, 0)), true, 'concave vertex')
local splitEdge = norm(poly({ v(0, 0, 0), v(2, 0, 0), v(4, 0, 0), v(4, 4, 0), v(0, 4, 0) }))
eq(Geometry.contains(splitEdge, v(3, 0, 0)), true, 'monotonic collinear edge accepted')
local far = norm(poly({ v(900000, 900000, 0), v(900001, 900000, 0), v(900001, 900001, 0), v(900000, 900001, 0) }))
eq(Geometry.contains(far, v(900000.5, 900000.5, 0)), true, 'far-origin area stable')

rejects(nil, 'nil definition')
rejects({}, 'missing type')
rejects({ type = 'capsule' }, 'unsupported type')
for _, bad in ipairs({ 0, -1, math.huge, -math.huge, 0/0, '10', 10001 }) do
    rejects({ type = 'sphere', coords = v(0, 0, 0), radius = bad }, 'invalid radius ' .. tostring(bad))
end
for _, bad in ipairs({ false, 'point', {}, { x = 0, y = 0 }, { x = 0/0, y = 0, z = 0 }, { x = math.huge, y = 0, z = 0 } }) do
    rejects({ type = 'sphere', coords = bad, radius = 1 }, 'invalid coords')
    eq(Geometry.contains(sphere, bad), false, 'bad query coords fail closed')
end
rejects({ type = 'box', coords = v(0, 0, 0), size = v(0, 2, 2) }, 'flat box')
rejects({ type = 'box', coords = v(0, 0, 0), size = v(2, -1, 2) }, 'negative box')
rejects({ type = 'box', coords = v(0, 0, 0), size = v(10001, 2, 2) }, 'oversized box')
rejects({ type = 'box', coords = v(0, 0, 0), size = v(2, 2, 2), rotation = math.huge }, 'infinite rotation')
rejects(poly({ v(0, 0, 0), v(1, 1, 0) }), 'too few points')
rejects(poly({ v(0, 0, 0), v(4, 4, 0), v(0, 4, 0), v(4, 0, 0) }), 'bowtie')
rejects(poly({ v(0, 0, 0), v(4, 0, 0), v(2, 0, 0), v(4, 4, 0), v(0, 4, 0) }), 'backtracking adjacent edge')
rejects(poly({ v(0, 0, 0), v(1, 0, 0), v(2, 0, 0) }), 'collinear polygon')
rejects(poly({ v(0, 0, 0), v(4, 0, 0), v(4, 4, 0), v(0, 0, 0) }), 'duplicate closing vertex')
rejects(poly({ v(0, 0, 0), v(4, 0, 0), v(4, 4, 0), v(2, 0, 0), v(0, 4, 0) }), 'nonadjacent edge touch')
rejects(poly({ v(0, 0, 0), v(10001, 0, 0), v(0, 4, 0) }), 'polygon extent')
rejects(poly({ v(0, 0, 0), v(4, 0, 0), v(0, 4, 0) }, 2, 2), 'zero height')
rejects(poly({ v(0, 0, 0), v(4, 0, 0), v(0, 4, 0) }, 3, 2), 'inverted height')
rejects(poly({ v(0, 0, 0), v(4, 0, 0), v(0, 4, 0) }, 0, math.huge), 'nonfinite height')
local many = {}
for i = 1, 257 do many[i] = v(math.cos(i / 257 * 2 * math.pi), math.sin(i / 257 * 2 * math.pi), 0) end
rejects(poly(many), 'polygon count bound')
many[257] = nil
norm(poly(many))
local dictionary = { v(0, 0, 0), v(1, 0, 0), v(0, 1, 0), extra = v(2, 2, 0) }
rejects(poly(dictionary), 'non-array vertices')
eq(Geometry.contains(nil, v(0, 0, 0)), false, 'nil shape')
eq(Geometry.contains({}, v(0, 0, 0)), false, 'malformed shape')
eq(Geometry.contains({ type = 'polygon', coords = v(0, 0, 0), minZ = -2, maxZ = 2, points = { false, {}, {} } }, v(0, 0, 0)), false, 'malformed normalized vertices')

-- Rotation invariance, both vertex winding orders, and scalar table queries.
for degrees = 0, 345, 15 do
    local shape = norm({ type = 'box', coords = v(2, 3, 4), size = v(8, 2, 6), rotation = degrees })
    local r = math.rad(degrees)
    local c, s = math.cos(r), math.sin(r)
    eq(Geometry.contains(shape, { x = 2 + c * 4 - s, y = 3 + s * 4 + c, z = 7 }), true, 'rotated corner ' .. degrees)
    eq(Geometry.contains(shape, { 2 - s * 1.1, 3 + c * 1.1, 4 }), false, 'rotated miss ' .. degrees)
end
print(('geometry: %d passed, 0 failed'):format(passed))
