--[[
    core/client/markers.lua -- Core.Markers (DESIGN §6.4).

    Markers are world entries drawn by the single world draw loop (§6.3); this
    file never starts a loop of its own. Ids are 'owner:mN' and are tracked in
    Core.Registry, so a plugin's markers disappear when the plugin stops.
]]

local World <const> = Core.World
local Registry <const> = Core.Registry

local DEFAULT_COLOR <const> = { 0, 150, 255, 120 }
local DEFAULT_DISTANCE <const> = 30.0

---@type table<string, integer>  owner -> last marker number
local counters = {}

---@param owner string
---@return string
local function nextId(owner)
    local n = (counters[owner] or 0) + 1
    counters[owner] = n
    return owner .. ':m' .. n
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

---@param value any
---@param fallback number
---@return number
local function num(value, fallback)
    local n = tonumber(value)
    return n and n or fallback
end

---@param value any
---@param fallback integer
---@return integer
local function byte(value, fallback)
    local n = tonumber(value)
    if not n then return fallback end
    return math.floor(math.max(0, math.min(255, n)))
end

--- Apply `opts` onto the marker table `m` (partial update: absent keys stay).
---@param m table
---@param opts table
local function apply(m, opts)
    local coords = opts.coords and toVector3(opts.coords)
    if coords then m.coords = coords end

    if opts.type ~= nil then m.type = math.floor(num(opts.type, m.type)) end
    if opts.drawDistance ~= nil then m.drawDistance = math.max(1.0, num(opts.drawDistance, m.drawDistance)) end
    if opts.offsetZ ~= nil then m.offsetZ = num(opts.offsetZ, m.offsetZ) end
    if opts.bobUpAndDown ~= nil then m.bob = opts.bobUpAndDown == true end
    if opts.faceCamera ~= nil then m.faceCamera = opts.faceCamera == true end
    if opts.rotate ~= nil then m.rotate = opts.rotate == true end

    if opts.size ~= nil then
        local size = toVector3(opts.size)
        if size then
            m.sx, m.sy, m.sz = size.x, size.y, size.z
        else
            local s = num(opts.size, 1.0)
            m.sx, m.sy, m.sz = s, s, s
        end
    end

    if type(opts.color) == 'table' then
        local c = opts.color
        m.r = byte(c.r or c[1], m.r)
        m.g = byte(c.g or c[2], m.g)
        m.b = byte(c.b or c[3], m.b)
        m.a = byte(c.a or c[4], m.a)
    end
end

--- World draw callback. Local function, called per frame while in range.
---@param entry table
local function drawMarker(entry)
    local m = entry.data
    if not m then return end
    local c = m.coords
    DrawMarker(m.type, c.x, c.y, c.z + m.offsetZ, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        m.sx, m.sy, m.sz, m.r, m.g, m.b, m.a, m.bob, m.faceCamera, 2, m.rotate, nil, nil, false)
end

local Markers = {}

--- Create a marker. Returns its id, or nil when `coords` is missing/invalid.
---@param opts table
---@return string|nil
function Markers.add(opts)
    if type(opts) ~= 'table' then return nil end

    local coords = toVector3(opts.coords)
    if not coords then return nil end

    local owner = Registry.getCaller()
    local id = nextId(owner)
    local m = {
        coords = coords, type = 1, drawDistance = DEFAULT_DISTANCE, offsetZ = 0.0,
        bob = false, faceCamera = false, rotate = false,
        sx = 1.0, sy = 1.0, sz = 1.0,
        r = DEFAULT_COLOR[1], g = DEFAULT_COLOR[2], b = DEFAULT_COLOR[3], a = DEFAULT_COLOR[4],
    }
    apply(m, opts)

    if not World.add('marker', id, m.coords, m.drawDistance, drawMarker) then return nil end
    World.get(id).data = m
    Registry.track('marker', id, owner)
    return id
end

--- Change any subset of a marker's options.
---@param id string
---@param opts table
---@return boolean
function Markers.update(id, opts)
    if type(id) ~= 'string' or type(opts) ~= 'table' then return false end

    local entry = World.get(id)
    if not entry or entry.kind ~= 'marker' then return false end

    apply(entry.data, opts)
    return World.update(id, entry.data.coords, entry.data.drawDistance)
end

--- Remove one marker.
---@param id string
---@return boolean
function Markers.remove(id)
    if type(id) ~= 'string' then return false end

    local entry = World.get(id)
    if not entry or entry.kind ~= 'marker' then return false end

    Registry.untrack('marker', id)
    return World.remove('marker', id)
end

--- Remove every marker of the calling resource.
---@return integer removed
function Markers.removeAll()
    local owner = Registry.getCaller()
    local ids = Registry.idsOf('marker', owner)
    local removed = 0
    for i = 1, #ids do
        if Markers.remove(ids[i]) then removed = removed + 1 end
    end
    return removed
end

-- Automatic cleanup when the owning resource stops (registered once, §2.3).
Registry.onOwnerStop('marker', function(id)
    World.remove('marker', id)
end)

Core.Markers = Markers
