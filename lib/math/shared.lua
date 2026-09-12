--[[
    core/lib/math/shared.lua — Core.Math (DESIGN §3.2).

    Pure vector and heading helpers, no natives. GTA convention: heading 0 looks north
    (+Y), headings grow counter-clockwise, rotations are degrees in a vector3 (x = pitch,
    y = roll, z = yaw).
]]

local ns = ...

local rad, deg = math.rad, math.deg
local sin, cos, atan, sqrt, abs, floor = math.sin, math.cos, math.atan, math.sqrt, math.abs, math.floor

--------------------------------------------------------------------------------
-- Distances
--------------------------------------------------------------------------------

function ns.distance(a, b)
    return #(a - b)
end

function ns.distance2d(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

--------------------------------------------------------------------------------
-- Headings and directions
--------------------------------------------------------------------------------

--- Heading in degrees -> unit forward vector on the ground plane.
function ns.headingToDirection(h)
    local r = rad(h)
    return vector3(-sin(r), cos(r), 0.0)
end

--- Ground-plane direction -> heading in degrees, normalised to [0, 360).
function ns.directionToHeading(dir)
    return ns.normalizeHeading(deg(atan(-dir.x, dir.y)))
end

function ns.normalizeHeading(h)
    return (h + 0.0) % 360.0
end

--- GTA camera/entity rotation (degrees) -> unit forward vector.
function ns.rotationToDirection(rot)
    local rx, rz = rad(rot.x), rad(rot.z)
    local flat = abs(cos(rx))
    return vector3(-sin(rz) * flat, cos(rz) * flat, sin(rx))
end

--- coords moved by forward/right/up metres relative to heading.
function ns.offset(coords, heading, forward, right, up)
    local r = rad(heading)
    local sinH, cosH = sin(r), cos(r)
    forward, right, up = forward or 0.0, right or 0.0, up or 0.0
    return vector3(
        coords.x - sinH * forward + cosH * right,
        coords.y + cosH * forward + sinH * right,
        coords.z + up
    )
end

--------------------------------------------------------------------------------
-- Volumes
--------------------------------------------------------------------------------

function ns.isInsideSphere(p, center, radius)
    return #(p - center) <= radius
end

--- Axis-aligned box; min/max are the two opposite corners in any order.
function ns.isInsideBox(p, min, max)
    local minX, maxX = min.x, max.x
    local minY, maxY = min.y, max.y
    local minZ, maxZ = min.z, max.z
    if minX > maxX then minX, maxX = maxX, minX end
    if minY > maxY then minY, maxY = maxY, minY end
    if minZ > maxZ then minZ, maxZ = maxZ, minZ end
    return p.x >= minX and p.x <= maxX
        and p.y >= minY and p.y <= maxY
        and p.z >= minZ and p.z <= maxZ
end

--------------------------------------------------------------------------------
-- Conversions
--------------------------------------------------------------------------------

function ns.deg2rad(d)
    return rad(d)
end

function ns.rad2deg(r)
    return deg(r)
end

local function roundTo(n, mult)
    return floor(n * mult + 0.5) / mult
end

function ns.roundVector(v, decimals)
    local mult = 10 ^ (decimals or 0)
    return vector3(roundTo(v.x, mult), roundTo(v.y, mult), roundTo(v.z, mult))
end
