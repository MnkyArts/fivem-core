-- Core.Geometry (DESIGN §40): shared, edge-inclusive volumes. No natives.
-- Normalize once at registration, then use contains for client hints or server checks.
local ns = ...
local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt
local EPS <const> = 1e-7
local COORD_LIMIT <const> = 1000000
local EXTENT_LIMIT <const> = 10000
local MAX_POINTS <const> = 256

local function finite(n, limit)
    return type(n) == 'number' and n == n and abs(n) <= (limit or COORD_LIMIT)
end

local function xyz(p)
    local t = type(p)
    if t ~= 'table' and t ~= 'vector3' then return nil end
    local x, y, z = p.x, p.y, p.z
    if t == 'table' then x, y, z = x or p[1], y or p[2], z or p[3] end
    if not finite(x) or not finite(y) or not finite(z) then return nil end
    return x, y, z
end

local function point(p)
    local x, y, z = xyz(p)
    if x == nil then return nil end
    return vector3(x, y, z)
end

local function cross(a, b, c)
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
end

local function onSegment(a, b, p)
    local dx, dy = b.x - a.x, b.y - a.y
    local length = sqrt(dx * dx + dy * dy)
    return abs(cross(a, b, p)) <= EPS * max(1, length)
        and p.x >= min(a.x, b.x) - EPS and p.x <= max(a.x, b.x) + EPS
        and p.y >= min(a.y, b.y) - EPS and p.y <= max(a.y, b.y) + EPS
end

local function intersects(a, b, c, d)
    local abC, abD, cdA, cdB = cross(a, b, c), cross(a, b, d), cross(c, d, a), cross(c, d, b)
    if ((abC > 0 and abD < 0) or (abC < 0 and abD > 0))
        and ((cdA > 0 and cdB < 0) or (cdA < 0 and cdB > 0)) then return true end
    return onSegment(a, b, c) or onSegment(a, b, d) or onSegment(c, d, a) or onSegment(c, d, b)
end

local function polygon(def)
    local source = def.points
    if type(source) ~= 'table' then return nil, 'points_required' end
    local n = #source
    if n < 3 or n > MAX_POINTS then return nil, 'point_count' end
    -- Reject sparse/dictionary shapes rather than silently ignoring an omitted vertex.
    for k in pairs(source) do
        if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 or k > n then return nil, 'point_count' end
    end
    if not finite(def.minZ) or not finite(def.maxZ) or def.maxZ <= def.minZ
        or def.maxZ - def.minZ > EXTENT_LIMIT then return nil, 'height' end
    local points, loX, loY, hiX, hiY = {}, math.huge, math.huge, -math.huge, -math.huge
    for i = 1, n do
        local p = point(source[i])
        if not p then return nil, 'point' end
        points[i] = p
        loX, loY, hiX, hiY = min(loX, p.x), min(loY, p.y), max(hiX, p.x), max(hiY, p.y)
        for j = 1, i - 1 do
            if abs(p.x - points[j].x) <= EPS and abs(p.y - points[j].y) <= EPS then
                return nil, 'duplicate_point'
            end
        end
    end
    if hiX - loX > EXTENT_LIMIT or hiY - loY > EXTENT_LIMIT then return nil, 'extent' end
    local area = 0
    for i = 1, n do
        local a, b = points[i], points[i % n + 1]
        -- Origin-relative triangle area avoids cancellation far from the map origin.
        area = area + cross(points[1], a, b)
        local c = points[(i + 1) % n + 1]
        if onSegment(a, b, c) or onSegment(b, c, a) then return nil, 'overlapping_edges' end
        for j = i + 1, n do
            if j ~= i + 1 and not (i == 1 and j == n) then
                if intersects(a, b, points[j], points[j % n + 1]) then return nil, 'intersecting_edges' end
            end
        end
    end
    if abs(area) <= EPS then return nil, 'area' end
    local cx, cy, cz = (loX + hiX) / 2, (loY + hiY) / 2, (def.minZ + def.maxZ) / 2
    local radius2 = 0
    for i = 1, n do
        local p = points[i]
        radius2 = max(radius2, (p.x - cx) ^ 2 + (p.y - cy) ^ 2)
    end
    return { type = 'polygon', coords = vector3(cx, cy, cz), points = points,
        minZ = def.minZ, maxZ = def.maxZ, radius = sqrt(radius2 + ((def.maxZ - def.minZ) / 2) ^ 2),
        bounds = { minX = loX, minY = loY, maxX = hiX, maxY = hiY } }
end

--- Returns a detached normalized shape, or nil and a stable validation reason.
function ns.normalize(def)
    if type(def) ~= 'table' then return nil, 'definition' end
    if def.type == 'polygon' or def.type == 'poly' then return polygon(def) end
    if def.type ~= 'sphere' and def.type ~= 'box' then return nil, 'type' end
    local coords = point(def.coords)
    if not coords then return nil, 'coords' end
    if def.type == 'sphere' then
        local r = def.radius
        if not finite(r, EXTENT_LIMIT) or r <= EPS then return nil, 'radius' end
        return { type = 'sphere', coords = coords, radius = r, minZ = coords.z - r, maxZ = coords.z + r,
            bounds = { minX = coords.x - r, minY = coords.y - r, maxX = coords.x + r, maxY = coords.y + r } }
    end
    local sx, sy, sz = xyz(def.size)
    if not sx or min(sx, sy, sz) <= EPS or max(sx, sy, sz) > EXTENT_LIMIT then return nil, 'size' end
    local rotation = def.rotation == nil and 0 or def.rotation
    if not finite(rotation) then return nil, 'rotation' end
    rotation = rotation % 360
    local c, s = math.cos(math.rad(rotation)), math.sin(math.rad(rotation))
    local hx, hy = (abs(c) * sx + abs(s) * sy) / 2, (abs(s) * sx + abs(c) * sy) / 2
    return { type = 'box', coords = coords, size = vector3(sx, sy, sz), rotation = rotation,
        radius = sqrt(sx * sx + sy * sy + sz * sz) / 2, minZ = coords.z - sz / 2, maxZ = coords.z + sz / 2,
        bounds = { minX = coords.x - hx, minY = coords.y - hy, maxX = coords.x + hx, maxY = coords.y + hy } }
end

--- Test a normalized volume. Height and boundary edges are inclusive.
function ns.contains(shape, coords)
    if type(shape) ~= 'table' then return false end
    local x, y, z = xyz(coords)
    local cx, cy, cz = xyz(shape.coords)
    if x == nil or cx == nil then return false end
    local dx, dy, dz = x - cx, y - cy, z - cz
    if shape.type == 'sphere' then
        return finite(shape.radius, EXTENT_LIMIT) and shape.radius > 0
            and dx * dx + dy * dy + dz * dz <= (shape.radius + EPS) ^ 2
    end
    if shape.type == 'box' then
        local sx, sy, sz = xyz(shape.size)
        if not sx or min(sx, sy, sz) <= 0 or not finite(shape.rotation) then return false end
        local r = math.rad(shape.rotation)
        local c, s = math.cos(r), math.sin(r)
        return abs(c * dx + s * dy) <= sx / 2 + EPS and abs(-s * dx + c * dy) <= sy / 2 + EPS
            and abs(dz) <= sz / 2 + EPS
    end
    if shape.type ~= 'polygon' or not finite(shape.minZ) or not finite(shape.maxZ)
        or z < shape.minZ - EPS or z > shape.maxZ + EPS or type(shape.points) ~= 'table' then return false end
    local points, inside = shape.points, false
    local n = #points
    if n < 3 or n > MAX_POINTS then return false end
    local p = { x = x, y = y }
    for i = 1, n do
        local a, b = points[i], points[i % n + 1]
        if xyz(a) == nil or xyz(b) == nil then return false end
        if onSegment(a, b, p) then return true end
        if (a.y > y) ~= (b.y > y) and x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x then
            inside = not inside
        end
    end
    return inside
end
