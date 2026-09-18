--[[
    core/server/getters.lua — proximity and lookup getters (DESIGN §22).

    Extends the existing `Core.Player` (server/player.lua) and `Core.Vehicles` (server/vehicles.lua)
    tables; both files load before this one (fxmanifest order), so the tables are the module tables,
    not import.lua's lazy proxies.

    The proximity getters (`getClosest`, `getInRange`) ask `Core.PlayerGrid` (§22.1) for the
    candidates of the queried circle and test the EXACT distance with live coordinates on those
    only — identical results, without the full loop over every loaded player (§9). Everything else
    here is O(players) or O(core vehicles) per call and meant for event handlers and commands —
    never for a per-tick loop. `Player.getStreet` asks the player's own client
    (Core.Callback.awaitClient) and therefore yields: call it from a thread/handler coroutine.

    Server side only: every native below is apiset server (or client+server) — note that
    GetVehicleMaxNumberOfPassengers is client-only, so seat scans use a fixed seat-index range.
]]

local Player = Core.Player
local Vehicles = Core.Vehicles
local Validate = Core.Validate
local PlayerGrid = Core.PlayerGrid   -- server/playergrid.lua loads before this file (manifest order)

-- Reusable candidate buffers (§22.1): neither getter yields, and each one has its own array, so a
-- nested call can never clobber the other's. Only the returned count is meaningful — the tail is stale.
local closestBuffer = {}
local inRangeBuffer = {}

local DEFAULT_PLAYER_RANGE <const> = 50.0
local DEFAULT_VEHICLE_RANGE <const> = 20.0
local MAX_RANGE <const> = 2000.0
local DRIVER_SEAT <const> = -1
-- GTA's highest passenger seat index; GetVehicleMaxNumberOfPassengers is apiset client, so the
-- server scans the whole range and skips empty seats (GetPedInVehicleSeat returns 0 for those).
local MAX_SEAT_INDEX <const> = 15
local VEHICLE_COLLECTION <const> = 'vehicles'   -- mirrors COLLECTION in server/vehicles.lua
local MAX_META_KEY <const> = 64

--- vector3 from a vector3 or a { x, y, z } / { [1], [2], [3] } table; nil when unusable.
local function toVector3(value)
    if type(value) == 'vector3' then return value end
    if type(value) ~= 'table' then return nil end
    local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    local coords = vector3(x + 0.0, y + 0.0, z + 0.0)
    return Validate.value('vector3', coords) and coords or nil
end

--- A positive, sane range; falls back to `default` for anything else.
local function rangeOf(value, default)
    if type(value) ~= 'number' or value ~= value or value <= 0.0 then return default end
    return math.min(value, MAX_RANGE)
end

--- Live world coordinates of a connected player, or nil when the ped is not (yet) there.
local function coordsOf(src)
    if not Validate.value('src', src) then return nil end
    local ped = GetPlayerPed(src)
    if ped == 0 then return nil end
    return GetEntityCoords(ped)
end

--- Every connected server id (GetPlayers is a runtime helper, not a native).
local function connectedSrcs()
    local players = GetPlayers()
    local out = {}
    for i = 1, #players do
        local src = tonumber(players[i])
        if src then out[#out + 1] = math.tointeger(src) or nil end
    end
    return out
end

--- { [ped] = src } for every connected player; built once per call instead of per seat.
local function pedOwners()
    local map = {}
    local srcs = connectedSrcs()
    for i = 1, #srcs do
        local ped = GetPlayerPed(srcs[i])
        if ped ~= 0 then map[ped] = srcs[i] end
    end
    return map
end

--- Entity handle for a netId: core vehicles through the registry, anything else through the
--- network id. Returns 0 when the vehicle does not exist on this server.
local function vehicleEntity(netId)
    if not Validate.value('netId', netId) then return 0 end
    local entity = Vehicles.getEntity(netId)
    if entity ~= 0 then return entity end
    entity = NetworkGetEntityFromNetworkId(netId)
    if entity ~= 0 and DoesEntityExist(entity) then return entity end
    return 0
end

-- ---------------------------------------------------------------------------
-- Core.Player getters (DESIGN §22)
-- ---------------------------------------------------------------------------

--- Nearest other loaded player to `src`. Returns src, distance — or nil when nobody is in range.
function Player.getClosest(src, maxDist)
    local origin = coordsOf(src)
    if not origin then return nil end
    local range = rangeOf(maxDist, DEFAULT_PLAYER_RANGE)
    local bestSrc, bestDist
    local count = PlayerGrid.candidates(origin, range, closestBuffer)
    for i = 1, count do
        local other = closestBuffer[i]
        if other ~= src then
            local coords = coordsOf(other)
            if coords then
                local dist = #(coords - origin)
                if dist <= range and (not bestDist or dist < bestDist) then
                    bestSrc, bestDist = other, dist
                end
            end
        end
    end
    if not bestSrc then return nil end
    return bestSrc, bestDist
end

--- Every loaded player within `range` of `coords`, nearest first: { { src = src, dist = n }, ... }.
function Player.getInRange(coords, range)
    local origin = toVector3(coords)
    local out = {}
    if not origin then return out end
    local max = rangeOf(range, DEFAULT_PLAYER_RANGE)
    local count = PlayerGrid.candidates(origin, max, inRangeBuffer)
    for i = 1, count do
        local src = inRangeBuffer[i]
        local at = coordsOf(src)
        if at then
            local dist = #(at - origin)
            if dist <= max then out[#out + 1] = { src = src, dist = dist } end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

--- Character name first, connection name second; both compared case-insensitively.
local function namesOf(src)
    return Player.getName(src), GetPlayerName(src)
end

--- Exact, case-insensitive name match over loaded players. Returns src | nil.
function Player.findByName(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local wanted = name:lower()
    local players = Player.getPlayers()
    for i = 1, #players do
        local src = players[i]
        local charName, connName = namesOf(src)
        if (type(charName) == 'string' and charName:lower() == wanted)
            or (type(connName) == 'string' and connName:lower() == wanted) then
            return src
        end
    end
    return nil
end

--- Case-insensitive substring match (plain, no patterns) over loaded players. Returns an array of src.
function Player.findByPartialName(part)
    local out = {}
    if type(part) ~= 'string' or part == '' then return out end
    local wanted = part:lower()
    local players = Player.getPlayers()
    for i = 1, #players do
        local src = players[i]
        local charName, connName = namesOf(src)
        if (type(charName) == 'string' and charName:lower():find(wanted, 1, true))
            or (type(connName) == 'string' and connName:lower():find(wanted, 1, true)) then
            out[#out + 1] = src
        end
    end
    return out
end

--- Every connected player sitting in the vehicle with this netId. Returns an array of src.
function Player.getInVehicle(netId)
    local out = {}
    if not Validate.value('netId', netId) then return out end
    local srcs = connectedSrcs()
    for i = 1, #srcs do
        local src = srcs[i]
        local ped = GetPlayerPed(src)
        if ped ~= 0 then
            local vehicle = GetVehiclePedIsIn(ped, false)
            if vehicle ~= 0 and NetworkGetNetworkIdFromEntity(vehicle) == netId then
                out[#out + 1] = src
            end
        end
    end
    return out
end

--- True when the player's ped is within `range` of `coords`.
function Player.isNear(src, coords, range)
    local origin = toVector3(coords)
    local at = coordsOf(src)
    if not origin or not at then return false end
    return #(at - origin) <= rangeOf(range, DEFAULT_PLAYER_RANGE)
end

--- Street and zone name, read on the player's own client (§21 callback in client/hudfeed.lua).
--- Yields: call it from a thread, event handler or command. nil on timeout or without a session.
function Player.getStreet(src)
    if not Validate.value('src', src) or not Player.isLoaded(src) then return nil end
    local street, zone = Core.Callback.awaitClient(src, 'core:player:street')
    if type(street) ~= 'string' then return nil end
    return street, type(zone) == 'string' and zone or nil
end

-- ---------------------------------------------------------------------------
-- Core.Vehicles getters (DESIGN §22)
-- ---------------------------------------------------------------------------

--- Core-spawned vehicles within `range` of `coords`, nearest first. Returns an array of netId.
function Vehicles.getInRange(coords, range)
    local origin = toVector3(coords)
    local out = {}
    if not origin then return out end
    local max = rangeOf(range, DEFAULT_VEHICLE_RANGE)
    local found = {}
    local netIds = Vehicles.list()
    for i = 1, #netIds do
        local netId = netIds[i]
        local entity = Vehicles.getEntity(netId)
        if entity ~= 0 then
            local dist = #(GetEntityCoords(entity) - origin)
            if dist <= max then found[#found + 1] = { netId = netId, dist = dist } end
        end
    end
    table.sort(found, function(a, b) return a.dist < b.dist end)
    for i = 1, #found do out[i] = found[i].netId end
    return out
end

--- Server id of the driver, or nil when the seat is empty or held by an NPC.
function Vehicles.getDriver(netId)
    local entity = vehicleEntity(netId)
    if entity == 0 then return nil end
    local ped = GetPedInVehicleSeat(entity, DRIVER_SEAT)
    if ped == 0 then return nil end
    return pedOwners()[ped]
end

--- Server ids of the players in the passenger seats (driver excluded), seat order.
function Vehicles.getPassengers(netId)
    local out = {}
    local entity = vehicleEntity(netId)
    if entity == 0 then return out end
    local owners = pedOwners()
    for seat = 0, MAX_SEAT_INDEX do
        local ped = GetPedInVehicleSeat(entity, seat)
        if ped ~= 0 then
            local src = owners[ped]
            if src then out[#out + 1] = src end
        end
    end
    return out
end

--- Nearest core-spawned vehicle to the player's ped. Returns netId | nil.
function Vehicles.getClosestToPlayer(src, maxDist)
    local origin = coordsOf(src)
    if not origin then return nil end
    local list = Vehicles.getInRange(origin, rangeOf(maxDist, DEFAULT_VEHICLE_RANGE))
    return list[1]
end

--- setData/getData address the persisted record: an integer is a netId (the spawned vehicle must
--- have been persisted, Vehicles.persist), a string is a vehId. Returns the vehId | nil.
local function recordIdOf(target)
    if math.type(target) == 'integer' then
        local info = Vehicles.getInfo(target)
        local vehId = info and info.vehId
        return (type(vehId) == 'string' and vehId ~= '') and vehId or nil
    end
    return Validate.value('id', target) and target or nil
end

--- Write one key of the record's `meta` table (nil removes it). Persisted through Core.DB,
--- so it survives restarts — for live, replicated flags use the vehicle's state bag instead.
function Vehicles.setData(target, key, value)
    local vehId = recordIdOf(target)
    if not vehId then return false end
    if type(key) ~= 'string' or #key < 1 or #key > MAX_META_KEY then return false end
    local kind = type(value)
    if kind == 'function' or kind == 'thread' or kind == 'userdata' then return false end
    local record = Core.DB.get(VEHICLE_COLLECTION, vehId)
    if not record then return false end
    local meta = type(record.meta) == 'table' and record.meta or {}
    meta[key] = value
    -- DB.update runs jsonSafe over the patch, so a vector3 inside `value` is stored as { x, y, z }.
    return Core.DB.update(VEHICLE_COLLECTION, vehId, { meta = meta })
end

--- One key of the record's `meta`, or the whole (copied) meta table when `key` is nil.
function Vehicles.getData(target, key)
    local vehId = recordIdOf(target)
    if not vehId then return nil end
    local record = Core.DB.get(VEHICLE_COLLECTION, vehId)
    local meta = record and record.meta
    if type(meta) ~= 'table' then return nil end
    if key == nil then return meta end
    if type(key) ~= 'string' then return nil end
    return meta[key]
end
