--[[
    core/client/textlabels.lua -- Core.TextLabels (DESIGN §6.5).

    3D text drawn by the world draw loop (§6.3) via SetDrawOrigin, so the text
    is positioned by the engine and no screen projection is needed. Ids are
    'owner:tN' and are tracked in Core.Registry for automatic cleanup.
]]

local World <const> = Core.World
local Registry <const> = Core.Registry

local DEFAULT_COLOR <const> = { 255, 255, 255, 215 }
local DEFAULT_DISTANCE <const> = 15.0
local DEFAULT_SCALE <const> = 0.35
local DEFAULT_FONT <const> = 4
-- one GTA text component holds at most 99 characters; longer text is truncated
local MAX_TEXT <const> = 99

---@type table<string, integer>  owner -> last label number
local counters = {}

---@param owner string
---@return string
local function nextId(owner)
    local n = (counters[owner] or 0) + 1
    counters[owner] = n
    return owner .. ':t' .. n
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
---@param fallback integer
---@return integer
local function byte(value, fallback)
    local n = tonumber(value)
    if not n then return fallback end
    return math.floor(math.max(0, math.min(255, n)))
end

--- Trim any value to a drawable label string.
---@param value any
---@return string|nil
local function toText(value)
    if type(value) == 'number' then value = tostring(value) end
    if type(value) ~= 'string' or value == '' then return nil end
    return #value > MAX_TEXT and value:sub(1, MAX_TEXT) or value
end

--- Apply `opts` onto the label table `l` (partial update: absent keys stay).
---@param l table
---@param opts table
local function apply(l, opts)
    local coords = opts.coords and toVector3(opts.coords)
    if coords then l.coords = coords end

    local text = opts.text ~= nil and toText(opts.text) or nil
    if text then l.text = text end

    if opts.drawDistance ~= nil then
        l.drawDistance = math.max(1.0, tonumber(opts.drawDistance) or l.drawDistance)
    end
    if opts.scale ~= nil then
        l.scale = math.max(0.05, math.min(3.0, tonumber(opts.scale) or l.scale))
    end
    if opts.font ~= nil then
        l.font = math.floor(math.max(0, math.min(7, tonumber(opts.font) or l.font)))
    end

    if type(opts.color) == 'table' then
        local c = opts.color
        l.r = byte(c.r or c[1], l.r)
        l.g = byte(c.g or c[2], l.g)
        l.b = byte(c.b or c[3], l.b)
        l.a = byte(c.a or c[4], l.a)
    end
end

--- World draw callback. Local function, called per frame while in range.
---@param entry table
local function drawLabel(entry)
    local l = entry.data
    if not l then return end

    local c = l.coords
    SetDrawOrigin(c.x, c.y, c.z, 0)
    SetTextFont(l.font)
    SetTextScale(0.0, l.scale)
    SetTextColour(l.r, l.g, l.b, l.a)
    SetTextCentre(true)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextEdge(2, 0, 0, 0, 150)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(l.text)
    EndTextCommandDisplayText(0.0, 0.0, 0)
    ClearDrawOrigin()
end

local TextLabels = {}

--- Create a 3D text label. Returns its id, or nil on invalid coords/text.
---@param opts table
---@return string|nil
function TextLabels.add(opts)
    if type(opts) ~= 'table' then return nil end

    local coords = toVector3(opts.coords)
    local text = toText(opts.text)
    if not coords or not text then return nil end

    local owner = Registry.getCaller()
    local id = nextId(owner)
    local l = {
        coords = coords, text = text, drawDistance = DEFAULT_DISTANCE,
        scale = DEFAULT_SCALE, font = DEFAULT_FONT,
        r = DEFAULT_COLOR[1], g = DEFAULT_COLOR[2], b = DEFAULT_COLOR[3], a = DEFAULT_COLOR[4],
    }
    apply(l, opts)

    if not World.add('label', id, l.coords, l.drawDistance, drawLabel) then return nil end
    World.get(id).data = l
    Registry.track('label', id, owner)
    return id
end

--- Change any subset of a label's options.
---@param id string
---@param opts table
---@return boolean
function TextLabels.update(id, opts)
    if type(id) ~= 'string' or type(opts) ~= 'table' then return false end

    local entry = World.get(id)
    if not entry or entry.kind ~= 'label' then return false end

    apply(entry.data, opts)
    return World.update(id, entry.data.coords, entry.data.drawDistance)
end

--- Replace a label's text.
---@param id string
---@param text string
---@return boolean
function TextLabels.setText(id, text)
    local value = toText(text)
    if not value then return false end
    return TextLabels.update(id, { text = value })
end

--- Remove one label.
---@param id string
---@return boolean
function TextLabels.remove(id)
    if type(id) ~= 'string' then return false end

    local entry = World.get(id)
    if not entry or entry.kind ~= 'label' then return false end

    Registry.untrack('label', id)
    return World.remove('label', id)
end

--- Remove every label of the calling resource.
---@return integer removed
function TextLabels.removeAll()
    local ids = Registry.idsOf('label', Registry.getCaller())
    local removed = 0
    for i = 1, #ids do
        if TextLabels.remove(ids[i]) then removed = removed + 1 end
    end
    return removed
end

-- Automatic cleanup when the owning resource stops (registered once, §2.3).
Registry.onOwnerStop('label', function(id)
    World.remove('label', id)
end)

Core.TextLabels = TextLabels
