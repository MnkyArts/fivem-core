--[[ core — client/raycast.lua
     Core.Raycast (DESIGN §6.9): synchronous shape tests, no polling loop.
     StartExpensiveSynchronousShapeTestLosProbe returns a handle whose result is ready in the same
     frame, so GetShapeTestResult is read straight after it.
]]

local Raycast = {}

local DEFAULT_FLAGS <const> = -1     -- every intersect flag
local PROBE_OPTIONS <const> = 7      -- p8: the value the game itself uses for gameplay probes

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
    if not hit or hit == 0 then
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

Core.Raycast = Raycast

-- end of file
