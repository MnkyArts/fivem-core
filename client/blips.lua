--[[
    core/client/blips.lua -- Core.Blips (DESIGN §6.6).

    Static map blips: created once, styled once, never touched by a loop. Ids
    are 'owner:bN' and tracked in Core.Registry, so a plugin's blips vanish with
    the plugin. Also wraps the personal waypoint (set/get/clear).
]]

local Registry <const> = Core.Registry

local DEFAULT_SPRITE <const> = 1
local DEFAULT_COLOR <const> = 0
local DEFAULT_SCALE <const> = 0.8
local DEFAULT_ALPHA <const> = 255
local DEFAULT_DISPLAY <const> = 4
local WAYPOINT_SPRITE <const> = 8  -- GetFirstBlipInfoId(8) = the player's waypoint

---@type table<string, table>  id -> { handle = blip, opts = table }
local blips = {}
---@type table<string, integer>  owner -> last blip number
local counters = {}

---@param owner string
---@return string
local function nextId(owner)
    local n = (counters[owner] or 0) + 1
    counters[owner] = n
    return owner .. ':b' .. n
end

--- vector3 from a vector3 or a { x, y, z } / { [1], [2], [3] } table.
---@param value any
---@return vector3|nil
local function toVector3(value)
    if type(value) == 'vector3' then return value end
    if type(value) ~= 'table' then return nil end
    local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

--- The entity a blip should follow, from an `entity` handle or a `netId`.
---@param opts table
---@return integer|nil
local function resolveEntity(opts)
    local entity = tonumber(opts.entity)
    if not entity and tonumber(opts.netId) then
        local netId = math.floor(tonumber(opts.netId))
        -- an id the client does not hold yet resolves to nothing (and would log a console warning)
        entity = NetworkDoesEntityExistWithNetworkId(netId) and NetworkGetEntityFromNetworkId(netId) or 0
    end
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    return math.floor(entity)
end

--- Create the engine blip for `opts`; nil when nothing addressable was given.
---@param opts table
---@return integer|nil handle
---@return boolean isRadius
local function createHandle(opts)
    if type(opts.radius) == 'table' then
        local coords = toVector3(opts.radius.coords or opts.radius)
        local radius = tonumber(opts.radius.radius) or 50.0
        if not coords or radius <= 0.0 then return nil, false end
        return AddBlipForRadius(coords.x, coords.y, coords.z, radius + 0.0), true
    end

    local entity = resolveEntity(opts)
    if entity then return AddBlipForEntity(entity), false end

    local coords = toVector3(opts.coords)
    if not coords then return nil, false end
    return AddBlipForCoord(coords.x, coords.y, coords.z), false
end

--- Set the blip's name (the map legend entry).
---@param handle integer
---@param label string
local function applyLabel(handle, label)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(handle)
end

--- Apply any subset of the style options to an existing blip.
---@param handle integer
---@param opts table
---@param isRadius boolean
local function applyStyle(handle, opts, isRadius)
    if not isRadius and opts.sprite ~= nil then
        SetBlipSprite(handle, math.floor(tonumber(opts.sprite) or DEFAULT_SPRITE))
    end
    if opts.color ~= nil then
        SetBlipColour(handle, math.floor(tonumber(opts.color) or DEFAULT_COLOR))
    end
    if opts.scale ~= nil then
        SetBlipScale(handle, math.max(0.1, math.min(3.0, tonumber(opts.scale) or DEFAULT_SCALE)))
    end
    if opts.alpha ~= nil then
        SetBlipAlpha(handle, math.floor(math.max(0, math.min(255, tonumber(opts.alpha) or DEFAULT_ALPHA))))
    end
    if opts.display ~= nil then
        SetBlipDisplay(handle, math.floor(tonumber(opts.display) or DEFAULT_DISPLAY))
    end
    if opts.category ~= nil then
        SetBlipCategory(handle, math.floor(tonumber(opts.category) or 0))
    end
    if opts.shortRange ~= nil then
        SetBlipAsShortRange(handle, opts.shortRange == true)
    end
    if opts.route ~= nil then
        SetBlipRoute(handle, opts.route == true)
        if opts.route == true then
            SetBlipRouteColour(handle, math.floor(tonumber(opts.routeColor or opts.color) or DEFAULT_COLOR))
        end
    end
    if opts.label ~= nil and type(opts.label) == 'string' and opts.label ~= '' then
        applyLabel(handle, opts.label)
    end
end

local Blips = {}

local STYLE_KEYS <const> = {
    'sprite', 'color', 'scale', 'alpha', 'display', 'category', 'shortRange', 'route', 'routeColor', 'label',
}

--- Options as given, on top of the documented defaults (§6.6).
---@param opts table
---@return table
local function mergedStyle(opts)
    local style = {
        sprite = DEFAULT_SPRITE, color = DEFAULT_COLOR, scale = DEFAULT_SCALE, alpha = DEFAULT_ALPHA,
        display = DEFAULT_DISPLAY, shortRange = true, route = false, label = 'Blip',
    }
    for i = 1, #STYLE_KEYS do
        local key = STYLE_KEYS[i]
        if opts[key] ~= nil then style[key] = opts[key] end
    end
    return style
end

--- Remove the engine blip behind `id` without touching the registry.
---@param id string
---@return boolean
local function destroy(id)
    local blip = blips[id]
    if not blip then return false end
    blips[id] = nil
    if DoesBlipExist(blip.handle) then RemoveBlip(blip.handle) end
    return true
end

--- Create a blip (coords, radius, entity or netId). Returns its id or nil.
---@param opts table
---@return string|nil
function Blips.add(opts)
    if type(opts) ~= 'table' then return nil end

    local handle, isRadius = createHandle(opts)
    if not handle or handle == 0 or not DoesBlipExist(handle) then return nil end

    local style = mergedStyle(opts)
    applyStyle(handle, style, isRadius)

    local owner = Registry.getCaller()
    local id = nextId(owner)
    blips[id] = { handle = handle, isRadius = isRadius, opts = style }
    Registry.track('blip', id, owner)
    return id
end

--- Change any subset of a blip's style options.
---@param id string
---@param opts table
---@return boolean
function Blips.update(id, opts)
    local blip = type(id) == 'string' and blips[id] or nil
    if not blip or type(opts) ~= 'table' or not DoesBlipExist(blip.handle) then return false end

    for i = 1, #STYLE_KEYS do
        local key = STYLE_KEYS[i]
        if opts[key] ~= nil then blip.opts[key] = opts[key] end
    end
    applyStyle(blip.handle, opts, blip.isRadius)

    local coords = opts.coords and toVector3(opts.coords)
    if coords then SetBlipCoords(blip.handle, coords.x, coords.y, coords.z) end
    return true
end

--- Rename a blip.
---@param id string
---@param text string
---@return boolean
function Blips.setLabel(id, text)
    local blip = type(id) == 'string' and blips[id] or nil
    if not blip or type(text) ~= 'string' or text == '' or not DoesBlipExist(blip.handle) then return false end

    blip.opts.label = text
    applyLabel(blip.handle, text)
    return true
end

--- Move a blip.
---@param id string
---@param coords vector3
---@return boolean
function Blips.setCoords(id, coords)
    local blip = type(id) == 'string' and blips[id] or nil
    local pos = coords and toVector3(coords)
    if not blip or not pos or not DoesBlipExist(blip.handle) then return false end

    SetBlipCoords(blip.handle, pos.x, pos.y, pos.z)
    return true
end

--- Turn the GPS route to a blip on or off.
---@param id string
---@param enabled boolean
---@return boolean
function Blips.setRoute(id, enabled)
    local blip = type(id) == 'string' and blips[id] or nil
    if not blip or not DoesBlipExist(blip.handle) then return false end

    local on = enabled == true
    blip.opts.route = on
    SetBlipRoute(blip.handle, on)
    if on then
        SetBlipRouteColour(blip.handle, math.floor(tonumber(blip.opts.routeColor or blip.opts.color) or DEFAULT_COLOR))
    end
    return true
end

--- The engine blip handle, for natives core does not wrap.
---@param id string
---@return integer|nil
function Blips.getHandle(id)
    local blip = type(id) == 'string' and blips[id] or nil
    return blip and blip.handle or nil
end

--- Remove one blip.
---@param id string
---@return boolean
function Blips.remove(id)
    if type(id) ~= 'string' or not blips[id] then return false end

    Registry.untrack('blip', id)
    return destroy(id)
end

--- Remove every blip of the calling resource.
---@return integer removed
function Blips.removeAll()
    local ids = Registry.idsOf('blip', Registry.getCaller())
    local removed = 0
    for i = 1, #ids do
        if Blips.remove(ids[i]) then removed = removed + 1 end
    end
    return removed
end

--- Set the player's personal waypoint.
---@param coords vector3
---@return boolean
function Blips.setWaypoint(coords)
    local pos = coords and toVector3(coords)
    if not pos then return false end

    SetNewWaypoint(pos.x, pos.y)
    return true
end

--- The player's waypoint position (z is the blip's, not ground level), or nil.
---@return vector3|nil
function Blips.getWaypoint()
    if not IsWaypointActive() then return nil end

    local handle = GetFirstBlipInfoId(WAYPOINT_SPRITE)
    if handle == 0 or not DoesBlipExist(handle) then return nil end
    return GetBlipInfoIdCoord(handle)
end

--- Clear the player's waypoint.
function Blips.clearWaypoint()
    DeleteWaypointsFromThisPlayer()
end

-- Automatic cleanup when the owning resource stops (registered once, §2.3).
Registry.onOwnerStop('blip', function(id)
    destroy(id)
end)

Core.Blips = Blips
