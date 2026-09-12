--[[
    core/client/world.lua -- the world scheduler (DESIGN §6.3, §9).

    Internal to core: markers and text labels register a world entry and a local
    draw function here instead of running a loop of their own, so the framework
    has exactly ONE per-frame draw loop, and that loop sleeps 250 ms whenever
    nothing is in range.

    Thread A (scan, Config.World.ScanIntervalMs): one GetEntityCoords, the 3x3
    grid cells around the player, rebuild the visible set.
    Thread B (draw): Wait(0) while the visible set is non-empty, Wait(250) else.
]]

local worldCfg = (type(Config) == 'table' and Config.World) or {}
local GRID_SIZE <const> = tonumber(worldCfg.GridSize) or 100.0
local SCAN_MS <const> = math.floor(tonumber(worldCfg.ScanIntervalMs) or 500)
local IDLE_SCAN_MS <const> = 1000  -- nothing registered at all
local IDLE_DRAW_MS <const> = 250   -- nothing in range (DESIGN §9)

local floor <const> = math.floor

---@type table<string, table<string, table>>  cellKey -> id -> entry
local grid = {}
---@type table<string, table>  id -> entry
local byId = {}
local entryCount = 0

-- visible set: parallel arrays reused between scans (no per-scan allocation)
local visible, visibleDist, visibleCount = {}, {}, 0

-- widest draw range seen so far, in grid cells: an entry whose range is larger
-- than one cell would otherwise be culled by the 3x3 scan. Grows only, so the
-- scan never has to walk every entry to recompute it.
local scanRing = 1

--- Grow the scanned ring so `range` metres are always covered.
---@param range number
local function coverRange(range)
    if type(range) ~= 'number' or range ~= range then return end
    local cells = math.ceil(range / GRID_SIZE)
    if cells > scanRing then scanRing = cells end
end

--- core's logger, resolved lazily (Core.Log is loaded on first access).
---@param fmt string
---@param ... any
local function logError(fmt, ...)
    local log = Core.Log
    if log and log.error then
        log.error(fmt, ...)
    else
        print(('[core] ' .. fmt):format(...))
    end
end

--- Grid cell key for a world position.
---@param x number
---@param y number
---@return string
local function cellKey(x, y)
    return floor(x / GRID_SIZE) .. ':' .. floor(y / GRID_SIZE)
end

---@param entry table
---@param dist number
local function addVisible(entry, dist)
    for i = 1, visibleCount do
        if visible[i] == entry then
            visibleDist[i] = dist
            return
        end
    end
    visibleCount = visibleCount + 1
    visible[visibleCount] = entry
    visibleDist[visibleCount] = dist
end

---@param entry table
local function removeVisible(entry)
    for i = 1, visibleCount do
        if visible[i] == entry then
            visible[i] = visible[visibleCount]
            visibleDist[i] = visibleDist[visibleCount]
            visible[visibleCount] = nil
            visibleDist[visibleCount] = nil
            visibleCount = visibleCount - 1
            return
        end
    end
end

---@param entry table
local function gridInsert(entry)
    local key = cellKey(entry.coords.x, entry.coords.y)
    local cell = grid[key]
    if not cell then
        cell = {}
        grid[key] = cell
    end
    cell[entry.id] = entry
    entry.cell = key
end

---@param entry table
local function gridRemove(entry)
    local cell = grid[entry.cell]
    if not cell then return end
    cell[entry.id] = nil
    if next(cell) == nil then grid[entry.cell] = nil end
end

local World = {}

--- Register a drawable world entry. `draw(entry, dist)` is a local Lua function.
---@param kind string 'marker' | 'label'
---@param id string
---@param coords vector3
---@param range number
---@param draw fun(entry: table, dist: number)
---@return boolean
function World.add(kind, id, coords, range, draw)
    if type(id) ~= 'string' or type(draw) ~= 'function' or byId[id] then return false end
    if type(range) ~= 'number' or type(coords) ~= 'vector3' then return false end

    local entry = {
        kind = kind,
        id = id,
        coords = coords,
        range = range,
        draw = draw,
        data = nil,
    }
    byId[id] = entry
    entryCount = entryCount + 1
    gridInsert(entry)
    coverRange(range)

    -- show it without waiting for the next scan
    local dist = #(GetEntityCoords(PlayerPedId()) - coords)
    if dist <= range then addVisible(entry, dist) end
    return true
end

--- Drop an entry; it stops drawing on this frame, not on the next scan.
---@param kind string 'marker' | 'label'
---@param id string
---@return boolean
function World.remove(kind, id)
    local entry = byId[id]
    if not entry or entry.kind ~= kind then return false end
    removeVisible(entry)
    gridRemove(entry)
    byId[id] = nil
    entryCount = entryCount - 1
    return true
end

--- Move an entry and/or change its draw range.
---@param id string
---@param coords vector3|nil
---@param range number|nil
---@return boolean
function World.update(id, coords, range)
    local entry = byId[id]
    if not entry then return false end

    if coords then
        entry.coords = coords
        local key = cellKey(coords.x, coords.y)
        if key ~= entry.cell then
            gridRemove(entry)
            gridInsert(entry)
        end
    end
    if type(range) == 'number' then
        entry.range = range
        coverRange(range)
    end

    local dist = #(GetEntityCoords(PlayerPedId()) - entry.coords)
    if dist <= entry.range then addVisible(entry, dist) else removeVisible(entry) end
    return true
end

--- The entry table itself (markers/labels keep their options on `entry.data`).
---@param id string
---@return table|nil
function World.get(id)
    return byId[id]
end

-- Internal to core's client VM; markers.lua and textlabels.lua use it directly.
Core.World = World

-- Thread A: scan. One ped position read, then only the cells around the player
-- (3x3, widened when an entry draws further than one cell).
CreateThread(function()
    while true do
        local sleep = IDLE_SCAN_MS
        if entryCount > 0 then
            sleep = SCAN_MS
            local coords = GetEntityCoords(PlayerPedId())
            local cx, cy = floor(coords.x / GRID_SIZE), floor(coords.y / GRID_SIZE)
            local count = 0

            local ring = scanRing
            for gx = cx - ring, cx + ring do
                for gy = cy - ring, cy + ring do
                    local cell = grid[gx .. ':' .. gy]
                    if cell then
                        for _, entry in pairs(cell) do
                            local dist = #(coords - entry.coords)
                            if dist <= entry.range then
                                count = count + 1
                                visible[count] = entry
                                visibleDist[count] = dist
                            end
                        end
                    end
                end
            end

            for i = count + 1, visibleCount do
                visible[i] = nil
                visibleDist[i] = nil
            end
            visibleCount = count
        end
        Wait(sleep)
    end
end)

-- Thread B: draw. The framework's only per-frame loop besides interaction help.
CreateThread(function()
    while true do
        local count = visibleCount
        if count > 0 then
            local failed
            for i = 1, count do
                local entry = visible[i]
                if entry then
                    -- one bad draw callback must not kill the only draw loop
                    local ok, err = pcall(entry.draw, entry, visibleDist[i])
                    if not ok then
                        failed = failed or {}
                        failed[#failed + 1] = entry
                        failed[entry] = err
                    end
                end
            end

            if failed then
                for i = 1, #failed do
                    local entry = failed[i]
                    logError('world draw failed for %s %s, entry removed: %s',
                        tostring(entry.kind), tostring(entry.id), tostring(failed[entry]))
                    World.remove(entry.kind, entry.id)
                end
            end
            Wait(0)
        else
            Wait(IDLE_DRAW_MS)
        end
    end
end)
