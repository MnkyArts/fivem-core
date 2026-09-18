--[[
    core/server/playergrid.lua — Core.PlayerGrid (DESIGN §22.1), the server-side player spatial index.

    One staggered thread keeps a coarse grid of "which loaded player is roughly where"; every
    "who is near this position" answer (Player.getInRange/getClosest, Chat.sendNear, the chat
    proximity branch, /s) asks the grid for CANDIDATES and then does the exact distance test with
    live coordinates on those only. At 1,000–2,000 players the old full loop over every player was
    ~3 natives per player per query (DESIGN §9).

        PlayerGrid.candidates(coords, range, out) -> count   -- out[1..count]; the tail stays stale
        PlayerGrid.count()  -> integer                       -- players held by the grid
        PlayerGrid.cellOf(src) -> key|nil                    -- tests and debug only

    INTERNAL: `PlayerGrid` is in INTERNAL_NAMESPACES (server/api.lua), so it is not reachable through
    exports.core:call — plugins get the benefit through Core.Player.getInRange/getClosest and chat.

    Natives (verified with fxref 2026-09-18, both apiset server / CFX rows):
        GetPlayerPed(playerSrc) -> integer      GetEntityCoords(entity) -> vector3
        GetGameTimer() -> integer
]]

local PlayerGrid = {}
Core.PlayerGrid = PlayerGrid

local DEFAULT_CELL_SIZE <const> = 128.0
local MIN_CELL_SIZE <const> = 16.0
local MAX_CELL_SIZE <const> = 1024.0
--- Covers up to one refresh period of staleness: a vehicle at ~30 m/s moves 60 m in 2 s.
local SLACK <const> = 64.0
--- Wider than this (range + SLACK) and the cell walk costs more than the full player loop, so the
--- query takes the fallback instead. Every caller clamps far below it (getters 2000 m, chat 500 m).
local MAX_QUERY_RANGE <const> = 4096.0
local STEP_MS <const> = 250        -- one slice per step
local REFRESH_MS <const> = 2000    -- every player refreshed at least this often
local IDLE_MS <const> = 1000       -- nobody loaded: do nothing
local CELL_OFFSET <const> = 32768  -- key = (cx + OFFSET) * SPAN + (cy + OFFSET)
local CELL_SPAN <const> = 65536

--- Config.World.PlayerGridSize, resolved ONCE: the key encoding depends on it (§22.1).
local CELL_SIZE <const> = (function()
    local world = type(Config) == 'table' and Config.World or nil
    local size = type(world) == 'table' and tonumber(world.PlayerGridSize) or nil
    if not size or size ~= size then return DEFAULT_CELL_SIZE end
    return math.min(MAX_CELL_SIZE, math.max(MIN_CELL_SIZE, size + 0.0))
end)()

local cells = {}       -- [key] = { [src] = true }
local where = {}       -- [src] = { key, x, y, z, at }; the record table is REUSED, never re-allocated
local pending = {}     -- [src] = true: loaded, but no ped yet — always a candidate (§22.1)
local order = {}       -- the src array the refresh thread walks; rebuilt only when `dirty`
local orderCount = 0
local tracked = 0      -- #where
local cursor = 0       -- position in `order`
local dirty = true

--------------------------------------------------------------------------------
-- Cells
--------------------------------------------------------------------------------

--- Cell index of one world axis value, clamped into the key range. nil for NaN.
local function axisCell(v)
    if v ~= v then return nil end
    local c = math.floor(v / CELL_SIZE)
    if c < -CELL_OFFSET then return -CELL_OFFSET end
    if c >= CELL_OFFSET then return CELL_OFFSET - 1 end
    return c
end

local function keyOf(cx, cy)
    return (cx + CELL_OFFSET) * CELL_SPAN + (cy + CELL_OFFSET)
end

--- Removes `src` from its cell (and the cell when it runs empty). Keeps the record.
local function unlink(rec, src)
    local cell = cells[rec.key]
    if not cell then return end
    cell[src] = nil
    if next(cell) == nil then cells[rec.key] = nil end
end

--- Writes the live position of `src` into the index, moving cells only when the cell changed.
local function place(src, x, y, z)
    local cx, cy = axisCell(x), axisCell(y)
    if not cx or not cy then return end
    local key = keyOf(cx, cy)
    local rec = where[src]
    if not rec then
        rec = { key = false, x = 0.0, y = 0.0, z = 0.0, at = 0 }
        where[src] = rec
        tracked = tracked + 1
    elseif rec.key ~= key then
        unlink(rec, src)
    end
    if rec.key ~= key then
        local cell = cells[key]
        if not cell then
            cell = {}
            cells[key] = cell
        end
        cell[src] = true
        rec.key = key
    end
    rec.x, rec.y, rec.z, rec.at = x, y, z, GetGameTimer()
end

--- Two natives, no allocation beyond the vector the native returns. Returns false without a ped.
local function refresh(src)
    local ped = GetPlayerPed(src)
    if ped == 0 then
        -- loaded but not in the world yet: keep them in every candidate list (§22.1)
        if not where[src] then pending[src] = true end
        return false
    end
    pending[src] = nil
    local coords = GetEntityCoords(ped)
    place(src, coords.x, coords.y, coords.z)
    return true
end

--- Drops every trace of `src`. (The hook hands it (src, charId); the charId is not ours.)
local function forget(src)
    if type(src) ~= 'number' then return end
    pending[src] = nil
    local rec = where[src]
    if rec then
        unlink(rec, src)
        where[src] = nil
        tracked = tracked - 1
    end
    dirty = true
end

--------------------------------------------------------------------------------
-- Query (DESIGN §22.1) — the candidate set is approximate, the caller's test is exact
--------------------------------------------------------------------------------

--- Every src whose cell touches the box around `range + SLACK`, written into the caller's
--- reusable `out` array. Returns how many: `out` keeps its stale tail, so never use `#out`.
--- The caller still has to test the real distance with live coordinates.
--- While the grid is empty (first second after a start) this answers with every loaded player,
--- which is exactly the old full loop — correct, only slower.
function PlayerGrid.candidates(coords, range, out)
    if type(out) ~= 'table' then out = {} end
    local x, y
    if type(coords) == 'vector3' then
        x, y = coords.x, coords.y
    elseif type(coords) == 'table' then
        x, y = tonumber(coords.x or coords[1]), tonumber(coords.y or coords[2])
    end
    if type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then return 0 end

    local reach = tonumber(range) or 0.0
    if reach ~= reach or reach < 0.0 then reach = 0.0 end
    reach = reach + SLACK

    local count = 0
    -- nothing indexed yet, or a radius so wide that walking the cells costs more than the old
    -- full loop: answer with every loaded player, which is exactly what the callers did before
    if tracked == 0 or reach > MAX_QUERY_RANGE then
        local loaded = Core.Player.getPlayers()
        for i = 1, #loaded do
            count = count + 1
            out[count] = loaded[i]
        end
        return count
    end

    local minX, maxX = axisCell(x - reach), axisCell(x + reach)
    local minY, maxY = axisCell(y - reach), axisCell(y + reach)
    if not minX or not maxX or not minY or not maxY then return 0 end
    for cx = minX, maxX do
        for cy = minY, maxY do
            local cell = cells[keyOf(cx, cy)]
            if cell then
                for src in pairs(cell) do
                    count = count + 1
                    out[count] = src
                end
            end
        end
    end
    -- loaded players without a ped hold no cell, so they can never be a duplicate here; the
    -- session check keeps the candidate set exactly Player.getPlayers(), never wider
    if next(pending) ~= nil then
        for src in pairs(pending) do
            if Core.Player.isLoaded(src) then
                count = count + 1
                out[count] = src
            end
        end
    end
    return count
end

--- How many players the grid currently holds (0 = the fallback path above).
function PlayerGrid.count()
    return tracked
end

--- The cell key of `src`, or nil when the grid holds no record for them. Tests and debug.
function PlayerGrid.cellOf(src)
    local rec = where[src]
    return rec and rec.key or nil
end

--------------------------------------------------------------------------------
-- The one refresh thread (DESIGN §9, §22.1)
--------------------------------------------------------------------------------

--- The src array the thread walks; rebuilt only when the loaded player set changed.
local function rebuildOrder()
    local loaded = Core.Player.getPlayers()
    local n = #loaded
    for i = 1, n do order[i] = loaded[i] end
    for i = n + 1, orderCount do order[i] = nil end
    orderCount = n
    if cursor > n then cursor = 0 end
    dirty = false
end

CreateThread(function()
    while true do
        -- an empty order is rebuilt every idle step too: that costs one empty table on an empty
        -- server and makes the thread self-healing if a join event was ever missed
        if dirty or orderCount == 0 then rebuildOrder() end
        if orderCount == 0 then
            Wait(IDLE_MS)
        else
            -- one slice per step, so every player is refreshed once per REFRESH_MS
            local slice = math.ceil(orderCount * STEP_MS / REFRESH_MS)
            for _ = 1, slice do
                cursor = cursor + 1
                if cursor > orderCount then cursor = 1 end
                local src = order[cursor]
                if src then refresh(src) end
            end
            Wait(STEP_MS)
        end
    end
end)

--- A player entered the loaded set: rebuild the walk order and index them right away.
local function track(src)
    if type(src) ~= 'number' then return end
    dirty = true
    refresh(src)
end

-- The session is created here (server/player.lua's own handler ran first), long before the client
-- asks for its payload — without this the new src would not enter `order` until the next drop.
AddEventHandler('playerJoining', function()
    local src = source
    track(src)
end)

Core.on('playerLoaded', track)
Core.on('playerDropped', forget)
