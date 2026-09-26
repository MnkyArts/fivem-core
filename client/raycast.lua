--[[ core — client/raycast.lua
     Core.Raycast (DESIGN §6.9, §42): synchronous shape tests, no polling loop.
     StartExpensiveSynchronousShapeTestLosProbe returns a handle whose result is ready in the same
     frame, so GetShapeTestResult is read straight after it.

     §42 adds probes from the RENDERED camera (a scripted camera included — `fromCamera` follows the
     gameplay camera only) and from screen points. They are proxy calls for the occasional query; a
     per-frame tool calls the natives in its own VM instead.

     Natives (all apiset client, verified with fxref 2026-09-12 and 2026-09-26):
       StartExpensiveSynchronousShapeTestLosProbe(x1, y1, z1, x2, y2, z2, flags, entity, p8) -> handle
       GetShapeTestResult(handle) -> retval, BOOL hit (out), endCoords, surfaceNormal, entityHit
       GetGameplayCamCoord() -> vector3, GetGameplayCamRot(rotationOrder) -> vector3, PlayerPedId()
       GetWorldCoordFromScreenCoord(screenX, screenY) -> worldVector, normalVector   (CFX)
       GetScreenCoordFromWorldCoord(x, y, z) -> BOOL retval, screenX, screenY
       GetFinalRenderedCamCoord() -> vector3, GetFinalRenderedCamRot(rotationOrder) -> vector3
     BOOLs are read as `v == true or v == 1` (§30.4): the default invoke route answers the integer
     0/1 for an out-value, and `0` is truthy in Lua.
]]

local Raycast = {}

local DEFAULT_FLAGS <const> = -1     -- every intersect flag
local PROBE_OPTIONS <const> = 7      -- p8: the value the game itself uses for gameplay probes
local ROTATION_ORDER <const> = 2     -- the order every script passes to the camera rotation getters
local SCREEN_DISTANCE <const> = 1000.0
local MAX_DISTANCE <const> = 5000.0
local MIN_DIRECTION <const> = 1e-6   -- a normal shorter than this has no direction

--- BOOL return or out-value, whichever invoke route produced it (§30.4).
local function isTrue(value)
    return value == true or value == 1
end

local function finite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

--- A screen fraction: finite and inside 0..1 of the game viewport.
local function unit(n)
    return finite(n) and n >= 0.0 and n <= 1.0
end

--- Probe length: nil gives `default`, anything else must be finite and 0 < d <= 5000.
local function distanceArg(distance, default)
    if distance == nil then return default end
    if not finite(distance) or distance <= 0.0 or distance > MAX_DISTANCE then return nil end
    return distance + 0.0
end

--- Flags / entity handle: nil gives `default`, anything else must be a whole number.
local function integerArg(value, default)
    if value == nil then return default end
    if not finite(value) then return nil end
    return math.tointeger(value)
end

--- Probe between two points. Returns hit, coords, normal, entity (0 when nothing was hit).
---@param from vector3
---@param to vector3
---@param flags integer|nil intersect flags (default -1 = everything)
---@param ignoreEntity integer|nil entity the probe ignores (default 0)
---@return boolean hit, vector3 coords, vector3 normal, integer entity
function Raycast.between(from, to, flags, ignoreEntity)
    if not Core.Utils.isVector3(from) or not Core.Utils.isVector3(to) then
        return false, to or from, vector3(0.0, 0.0, 0.0), 0
    end

    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        from.x, from.y, from.z, to.x, to.y, to.z,
        flags or DEFAULT_FLAGS, ignoreEntity or 0, PROBE_OPTIONS)

    -- `hit` is a BOOL out-value: the integer 0/1 through the runtime's default invoke path (where
    -- `not 0` is false — a miss would read as a hit) and a real boolean through the direct one
    local _, hit, endCoords, normal, entityHit = GetShapeTestResult(handle)
    if not isTrue(hit) then
        return false, to, normal or vector3(0.0, 0.0, 0.0), 0
    end
    return true, endCoords, normal, entityHit or 0
end

--- Probe straight out of the gameplay camera.
---@param distance number|nil probe length in metres (default 10.0)
---@param flags integer|nil
---@param ignoreEntity integer|nil default: the local ped
---@return boolean hit, vector3 coords, vector3 normal, integer entity
function Raycast.fromCamera(distance, flags, ignoreEntity)
    local dist = tonumber(distance) or 10.0
    local from = GetGameplayCamCoord()
    local direction = Core.Math.rotationToDirection(GetGameplayCamRot(2))
    local to = from + (direction * dist)
    if ignoreEntity == nil then ignoreEntity = PlayerPedId() end
    return Raycast.between(from, to, flags, ignoreEntity)
end

--- Convenience: what the player is looking at.
---@param distance number|nil default 5.0
---@return integer entity 0 when nothing was hit
---@return vector3 coords
function Raycast.getEntityInFront(distance)
    local hit, coords, _, entity = Raycast.fromCamera(tonumber(distance) or 5.0)
    if not hit or not entity or entity == 0 then
        return 0, coords
    end
    return entity, coords
end

-- ------------------------------------------------ §42: rendered camera, screen points ----

--- The world point under a screen position and the direction a probe leaves it in, both
--- from the camera that is RENDERED right now (gameplay, scripted or cinematic).
---@param fx number 0..1 of the game viewport, left to right
---@param fy number 0..1 of the game viewport, top to bottom
---@return vector3|nil origin nil when the arguments are invalid
---@return vector3|nil direction unit vector; nil when the arguments are invalid or the native gave no direction
function Raycast.screenToWorld(fx, fy)
    if not unit(fx) or not unit(fy) then return nil, nil end
    local origin, normal = GetWorldCoordFromScreenCoord(fx + 0.0, fy + 0.0)
    if not Core.Utils.isVector3(origin) then return nil, nil end
    if not Core.Utils.isVector3(normal) then return origin, nil end
    local length = math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
    if not finite(length) or length < MIN_DIRECTION then return origin, nil end
    return origin, normal * (1.0 / length)
end

--- Where a world point lands on the screen of the rendered camera.
---@param coords vector3
---@return boolean onScreen false for a point behind or outside the camera, or invalid coords
---@return number|nil fx 0..1 of the viewport (nil when not on screen)
---@return number|nil fy
function Raycast.worldToScreen(coords)
    if not Core.Utils.isVector3(coords) or not finite(coords.x) or not finite(coords.y)
        or not finite(coords.z) then
        return false, nil, nil
    end
    local onScreen, fx, fy = GetScreenCoordFromWorldCoord(coords.x, coords.y, coords.z)
    if not isTrue(onScreen) or not finite(fx) or not finite(fy) then return false, nil, nil end
    return true, fx, fy
end

--- Probe from the rendered camera through a screen point (a cursor pick under any camera).
---@param fx number 0..1
---@param fy number 0..1
---@param distance number|nil metres, 0 < d <= 5000 (default 1000)
---@param flags integer|nil intersect flags (default -1 = everything)
---@param ignore integer|nil entity the probe ignores (default 0)
---@return boolean hit, vector3|nil coords, vector3|nil normal, integer entity  false, nil, nil, 0 on invalid arguments
function Raycast.fromScreen(fx, fy, distance, flags, ignore)
    local dist = distanceArg(distance, SCREEN_DISTANCE)
    local probeFlags, ignored = integerArg(flags, DEFAULT_FLAGS), integerArg(ignore, 0)
    if not dist or not probeFlags or not ignored then return false, nil, nil, 0 end
    local origin, direction = Raycast.screenToWorld(fx, fy)
    if not origin or not direction then return false, nil, nil, 0 end
    return Raycast.between(origin, origin + direction * dist, probeFlags, ignored)
end

--- Probe straight out of the rendered camera — `fromCamera` for scripted cameras too.
---@param distance number|nil metres, 0 < d <= 5000 (default 1000)
---@param flags integer|nil intersect flags (default -1 = everything)
---@param ignore integer|nil entity the probe ignores (default 0)
---@return boolean hit, vector3|nil coords, vector3|nil normal, integer entity  false, nil, nil, 0 on invalid arguments
function Raycast.fromRenderedCamera(distance, flags, ignore)
    local dist = distanceArg(distance, SCREEN_DISTANCE)
    local probeFlags, ignored = integerArg(flags, DEFAULT_FLAGS), integerArg(ignore, 0)
    if not dist or not probeFlags or not ignored then return false, nil, nil, 0 end
    local from = GetFinalRenderedCamCoord()
    local rotation = GetFinalRenderedCamRot(ROTATION_ORDER)
    if not Core.Utils.isVector3(from) or not Core.Utils.isVector3(rotation) then return false, nil, nil, 0 end
    local direction = Core.Math.rotationToDirection(rotation)
    return Raycast.between(from, from + direction * dist, probeFlags, ignored)
end

Core.Raycast = Raycast

-- end of file
