-- Core.Zones / Core.Points (DESIGN §40): owner-scoped proximity services.
-- Natives verified with fxref 2026-09-20: PlayerPedId, GetEntityCoords, GetGameTimer,
-- DrawLine, DrawMarker (client). Debug draws are local World scheduler callbacks.
local Registry, Geometry, Utils = Core.Registry, Core.Geometry, Core.Utils
local entries, inside, levels = {}, {}, {}
local sizes = { 100, 400, 1600, 6400, 25600, 102400, 409600 }
local count, sequence, epoch = 0, 0, 0
local Zones, Points = {}, {}
local floor, max = math.floor, math.max

local function callback(entry, name, distance)
    local fn = entry[name]
    if not fn then return end
    if name == 'nearby' and entry.busy then return end
    -- A plugin may await a modal in a callback: do not suspend the spatial scanner.
    -- One bounded queue per entry prevents a slow callback becoming unbounded work.
    local queue = entry.queue
    if #queue >= 8 then return end
    queue[#queue + 1] = { fn, distance }
    if entry.busy then return end
    entry.busy = true
    local function drain()
        if entries[entry.id] ~= entry then entry.busy = false; return end
        local item = table.remove(queue, 1)
        if item then
            local ok, err = pcall(item[1], entry.id, item[2])
            if not ok then Core.Log.error('proximity callback %s: %s', entry.id, tostring(err)) end
        end
        if #queue > 0 and entries[entry.id] == entry then SetTimeout(0, drain)
        else entry.busy = false end
    end
    SetTimeout(0, drain)
end

local function cellKey(x, y) return x .. ':' .. y end

local function index(entry)
    local b = entry.shape.bounds
    local span = max(b.maxX - b.minX, b.maxY - b.minY)
    local level = 1
    while level < #sizes and sizes[level] < span do level = level + 1 end
    local size = sizes[level]
    local grid = levels[level]
    if not grid then grid = {}; levels[level] = grid end
    entry.level, entry.cells = level, {}
    for x = floor(b.minX / size), floor(b.maxX / size) do
        for y = floor(b.minY / size), floor(b.maxY / size) do
            local key = cellKey(x, y)
            local cell = grid[key]
            if not cell then cell = {}; grid[key] = cell end
            cell[entry.id] = entry
            entry.cells[#entry.cells + 1] = key
        end
    end
end

local function remove(id, owner)
    local entry = entries[id]
    if not entry or entry.owner ~= owner then return false end
    entries[id], inside[id] = nil, nil
    count = count - 1
    local grid = levels[entry.level]
    for _, key in ipairs(entry.cells) do
        local cell = grid[key]
        cell[id] = nil
        if not next(cell) then grid[key] = nil end
    end
    if not next(grid) then levels[entry.level] = nil end
    entry.queue = {}
    if entry.debug then Core.World.remove('zone', id) end
    Registry.untrack(entry.kind, id)
    return true
end

local function debugLines(shape)
    local points = shape.points
    if shape.type == 'box' then
        points = {}
        local c, s = math.cos(math.rad(shape.rotation)), math.sin(math.rad(shape.rotation))
        for _, pair in ipairs({ {-1,-1}, {1,-1}, {1,1}, {-1,1} }) do
            local x, y = pair[1] * shape.size.x / 2, pair[2] * shape.size.y / 2
            points[#points + 1] = { x = shape.coords.x + x*c-y*s, y = shape.coords.y+x*s+y*c }
        end
    end
    local lines = {}
    if points then
        for i = 1, #points do
            local a, b = points[i], points[i % #points + 1]
            lines[#lines+1] = { a.x,a.y,shape.minZ,b.x,b.y,shape.minZ }
            lines[#lines+1] = { a.x,a.y,shape.maxZ,b.x,b.y,shape.maxZ }
            lines[#lines+1] = { a.x,a.y,shape.minZ,a.x,a.y,shape.maxZ }
        end
    end
    return lines
end

local function draw(entry)
    local zone = entries[entry.id]
    if not zone then return end
    local shape = zone.shape
    if shape.type == 'sphere' then
        local c, diameter = shape.coords, shape.radius * 2
        DrawMarker(28, c.x,c.y,c.z, 0.0,0.0,0.0, 0.0,0.0,0.0,
            diameter,diameter,diameter, 60,180,255,80, false,false,2,false,nil,nil,false)
    else
        for i = 1, #zone.lines do
            local line = zone.lines[i]
            DrawLine(line[1],line[2],line[3],line[4],line[5],line[6],60,180,255,180)
        end
    end
end

local function add(kind, options)
    if type(options) ~= 'table' or count >= 8192 then return nil end
    local shape, err
    if kind == 'point' then
        shape, err = Geometry.normalize({ type = 'sphere', coords = options.coords, radius = options.distance })
    else shape, err = Geometry.normalize(options) end
    if not shape then return nil, err end
    for _, name in ipairs({ 'onEnter', 'onExit', 'nearby' }) do
        if options[name] ~= nil and not Utils.isCallable(options[name]) then return nil end
    end
    local interval = options.interval or 250
    if math.type(interval) ~= 'integer' or interval < 100 or interval > 60000 then return nil end
    sequence = sequence + 1
    local id = 'core:' .. kind .. ':' .. sequence
    local entry = { id = id, kind = kind, owner = Registry.getCaller(), shape = shape,
        onEnter = options.onEnter, onExit = options.onExit,
        nearby = kind == 'point' and options.nearby or nil, interval = interval, nextNearby = 0,
        queue = {}, debug = kind == 'zone' and options.debug == true }
    entries[id], count = entry, count + 1
    index(entry)
    Registry.track(kind, id, entry.owner)
    if entry.debug then
        entry.lines = debugLines(shape)
        Core.World.add('zone', id, shape.coords, math.min(shape.radius + 50, 300), draw)
    end
    return id
end

function Zones.add(options) return add('zone', options) end
function Points.add(options) return add('point', options) end
function Zones.remove(id)
    return entries[id] and entries[id].kind == 'zone' and remove(id, Registry.getCaller()) or false
end
function Points.remove(id)
    return entries[id] and entries[id].kind == 'point' and remove(id, Registry.getCaller()) or false
end
local function removeAll(kind)
    local owner = Registry.getCaller()
    for _, id in ipairs(Registry.idsOf(kind, owner)) do remove(id, owner) end
end
function Zones.removeAll() removeAll('zone') end
function Points.removeAll() removeAll('point') end
function Zones.contains(id, coords)
    local entry = entries[id]
    return entry ~= nil and entry.kind == 'zone' and entry.owner == Registry.getCaller()
        and Geometry.contains(entry.shape, coords) or false
end
Registry.onOwnerStop('zone', remove)
Registry.onOwnerStop('point', remove)
Core.Zones, Core.Points = Zones, Points

CreateThread(function()
    while true do
        local sleep = 1000
        if count > 0 then
            sleep, epoch = 250, epoch + 1
            local coords, now = GetEntityCoords(PlayerPedId(), false), GetGameTimer()
            for level, grid in pairs(levels) do
                local size = sizes[level]
                local cell = grid[cellKey(floor(coords.x / size), floor(coords.y / size))]
                if cell then
                    for id, entry in pairs(cell) do
                        entry.epoch = epoch
                        local wasInside = inside[id] ~= nil
                        local isInside = Geometry.contains(entry.shape, coords)
                        if isInside then
                            inside[id] = entry
                            local distance = #(coords - entry.shape.coords)
                            if not wasInside then callback(entry, 'onEnter', distance) end
                            if entry.nearby and now >= entry.nextNearby then
                                entry.nextNearby = now + entry.interval
                                callback(entry, 'nearby', distance)
                            end
                        elseif wasInside then
                            inside[id] = nil
                            callback(entry, 'onExit', #(coords - entry.shape.coords))
                        end
                    end
                end
            end
            for id, entry in pairs(inside) do
                if entry.epoch ~= epoch then
                    inside[id] = nil
                    callback(entry, 'onExit', #(coords - entry.shape.coords))
                end
            end
        end
        Wait(sleep)
    end
end)
