--[[
    core/server/stats.lua — Core.Stats (DESIGN §18)

    Needs-style numeric stats (hunger, thirst, …) declared in Config.Stats.Defs and stored in the
    character document under `data.stats`, next to the counters server/player.lua keeps there
    (`deaths`, `playtime`): only names with a definition are read, written or replicated, so those
    counters ride along untouched.

    One decay thread serves every loaded player at Config.Stats.TickMs (`decayPerMinute` scaled to
    the tick). Values are clamped to min/max and rounded to two decimals. Crossing a threshold
    downwards emits `statThreshold (src, name, threshold, value)` — from decay as well as from an
    explicit change; `statChanged (src, name, value)` is emitted for set/add/sub/reset only, and
    only when the value really moved.

    Replication (DESIGN §8): `Player(src).state:set('stats', { [name] = value }, true)` — the whole
    table, server write only, at most once per second per player (dirty flag + deferred flush).

    Natives (verified with fxref 2026-09-12): GetGameTimer (CFX, apiset server). `Player(src).state`,
    `CreateThread`, `Wait` and `SetTimeout` are runtime helpers, not natives.
]]

local Stats = {}

local Log = Core.Log

local MIN_REPLICATE_MS <const> = 1000    -- §8 budget: one `stats` bag write per second per player
local MIN_TICK_MS <const> = 1000         -- floor for Config.Stats.TickMs
local MS_PER_MINUTE <const> = 60000
local MAX_NAME_LEN <const> = 32
local NAME_PATTERN <const> = '^[%a][%w_]*$'

local defs = {}           -- [name] = normalised definition
local lastSent = {}       -- [src] = GetGameTimer() of the last bag write
local dirty = {}          -- [src] = true while a change still has to be replicated
local flushPending = {}   -- [src] = true while a deferred flush is scheduled
local decayRunning = false

-- == Definitions and value handling ==

--- Config.Stats.Enabled, re-read on every call so a config change needs no code change here.
local function enabled()
    local cfg = Config.Stats
    return type(cfg) == 'table' and cfg.Enabled == true
end

--- Two decimals: enough for a HUD bar, small enough to keep the state-bag payload tiny.
local function roundValue(n)
    return math.floor(n * 100 + 0.5) / 100
end

--- A finite number (rejects nil, non-numbers, NaN and the infinities).
local function isFinite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

--- Validates and normalises one definition; nil when the shape is unusable.
local function normalizeDef(name, def)
    if type(def) ~= 'table' then return nil end
    local min = tonumber(def.min) or 0
    local max = tonumber(def.max) or 100
    if not isFinite(min) or not isFinite(max) or max <= min then return nil end

    local default = tonumber(def.default)
    if not isFinite(default) then default = max end
    if default < min then default = min elseif default > max then default = max end

    local decay = tonumber(def.decayPerMinute) or 0
    if not isFinite(decay) or decay < 0 then decay = 0 end

    local thresholds = {}
    if type(def.thresholds) == 'table' then
        for i = 1, #def.thresholds do
            local t = tonumber(def.thresholds[i])
            if isFinite(t) and t >= min and t <= max then thresholds[#thresholds + 1] = t end
        end
        table.sort(thresholds, function(a, b) return a > b end)   -- highest first
    end

    return {
        name = name, min = min, max = max, default = roundValue(default),
        decayPerMinute = decay, thresholds = thresholds, hud = def.hud == true,
    }
end

--- Any stored value -> a valid number for `def` (nil/garbage becomes the default).
local function clampValue(def, value)
    local n = tonumber(value)
    if not isFinite(n) then return def.default end
    if n < def.min then n = def.min elseif n > def.max then n = def.max end
    return roundValue(n)
end

-- == Document access and replication ==

--- The character's whole `stats` table (a copy from Core.Player.getData); nil without a session.
local function readStats(src)
    local player = Core.Player
    if not player or not player.isLoaded(src) then return nil end
    local stats = player.getData(src, 'stats')
    if type(stats) ~= 'table' then stats = {} end
    return stats
end

--- Writes the whole table back; `deaths`/`playtime` are preserved because they were read with it.
local function writeStats(src, stats)
    return Core.Player.setData(src, 'stats', stats) == true
end

--- The replicated value: defined stat names only, clamped.
local function buildPayload(stats)
    local out = {}
    for name, def in pairs(defs) do
        out[name] = clampValue(def, stats[name])
    end
    return out
end

--- Writes `player:<src>.stats`. Server-side write, replicated (DESIGN §8).
local function flush(src)
    dirty[src] = nil
    flushPending[src] = nil
    local stats = readStats(src)
    if not stats then
        lastSent[src] = nil
        return false
    end
    lastSent[src] = GetGameTimer()
    Player(src).state:set('stats', buildPayload(stats), true)
    return true
end

--- At most one bag write per second per player: send now, or schedule the rest of that second.
local function markDirty(src)
    dirty[src] = true
    if flushPending[src] then return end
    local since = GetGameTimer() - (lastSent[src] or -MIN_REPLICATE_MS)
    if since >= MIN_REPLICATE_MS then
        flush(src)
        return
    end
    flushPending[src] = true
    SetTimeout(MIN_REPLICATE_MS - since, function()
        flushPending[src] = nil
        if dirty[src] then flush(src) end
    end)
end

-- == Change engine ==

--- Emits statThreshold for every threshold the value crossed going down. Called after the
--- document was written, so a hook handler that yields can never race the write.
local function emitThresholds(src, def, oldValue, newValue)
    if newValue >= oldValue then return end
    local list = def.thresholds
    for i = 1, #list do
        local t = list[i]
        if oldValue > t and newValue <= t then
            Core.emitHook('statThreshold', src, def.name, t, newValue)
        end
    end
end

--- Current value of one stat, or nil when the player has no session.
local function currentValue(src, def)
    local stats = readStats(src)
    if not stats then return nil end
    return clampValue(def, stats[def.name])
end

--- Stores one clamped value, then fires the hooks and schedules replication.
--- `explicit` = a set/add/sub/reset call (statChanged); false for decay.
local function applyValue(src, def, value, explicit)
    local stats = readStats(src)
    if not stats then return false end

    local old = clampValue(def, stats[def.name])
    local new = clampValue(def, value)
    if stats[def.name] ~= new then
        stats[def.name] = new
        if not writeStats(src, stats) then return false end
    end
    if new == old then return true end

    emitThresholds(src, def, old, new)
    markDirty(src)
    if explicit then Core.emitHook('statChanged', src, def.name, new) end
    return true
end

--- Fills in missing or invalid values from `default`, clamps the rest, replicates once.
local function initPlayer(src)
    local stats = readStats(src)
    if not stats then return false end
    local changed = false
    for name, def in pairs(defs) do
        local value = clampValue(def, stats[name])
        if stats[name] ~= value then
            stats[name] = value
            changed = true
        end
    end
    if changed and not writeStats(src, stats) then return false end
    markDirty(src)      -- the bag needs the values even when the document already had them
    return true
end

-- == API (DESIGN §18) ==

--- Current value of `name`; 0 for an unknown stat or a player without a session.
function Stats.get(src, name)
    local def = defs[name]
    if not def then return 0 end
    return currentValue(src, def) or 0
end

--- Every defined stat as `{ [name] = value }` (a fresh table); empty without a session.
function Stats.getAll(src)
    local stats = readStats(src)
    if not stats then return {} end
    return buildPayload(stats)
end

--- Sets `name` to `value` (clamped). Emits statChanged when the value moved.
function Stats.set(src, name, value)
    local def = defs[name]
    if not def or not enabled() or not isFinite(value) then return false end
    return applyValue(src, def, value, true)
end

--- Adds a positive `delta` (use Stats.sub for the other direction, like Core.Money).
function Stats.add(src, name, delta)
    local def = defs[name]
    if not def or not enabled() or not isFinite(delta) or delta <= 0 then return false end
    local current = currentValue(src, def)
    if not current then return false end
    return applyValue(src, def, current + delta, true)
end

--- Subtracts a positive `delta`.
function Stats.sub(src, name, delta)
    local def = defs[name]
    if not def or not enabled() or not isFinite(delta) or delta <= 0 then return false end
    local current = currentValue(src, def)
    if not current then return false end
    return applyValue(src, def, current - delta, true)
end

--- Back to the default: one stat, or every stat when `name` is nil.
function Stats.reset(src, name)
    if not enabled() then return false end
    if name ~= nil then
        local def = defs[name]
        if not def then return false end
        return applyValue(src, def, def.default, true)
    end
    local any = false
    for _, def in pairs(defs) do
        if applyValue(src, def, def.default, true) then any = true end
    end
    return any
end

--- Validates and stores one definition. Returns false, or true plus whether the name is new.
local function registerDef(name, def)
    if type(name) ~= 'string' or name == '' or #name > MAX_NAME_LEN or not name:match(NAME_PATTERN) then
        return false
    end
    local normalized = normalizeDef(name, def)
    if not normalized then
        Log.warn('Stats: invalid definition for %s, ignored', tostring(name))
        return false
    end
    local isNew = defs[name] == nil
    defs[name] = normalized
    return true, isNew
end

--- Registers a stat definition `{ min, max, default, decayPerMinute, thresholds, hud }`.
--- Meant for resource start, before players load; a later call still gives already loaded players
--- the default, but only stats present in the client's Config.Stats.Defs get a HUD bar (§21).
function Stats.define(name, def)
    local ok, isNew = registerDef(name, def)
    if not ok then return false end
    local player = isNew and enabled() and Core.Player
    if player then
        local players = player.getPlayers()
        for i = 1, #players do initPlayer(players[i]) end
    end
    return true
end

-- == Decay, lifecycle ==

--- One decay pass over every loaded player. The document is written first and the hooks fire
--- afterwards, so a handler that yields cannot interleave with the write.
local function decayTick(elapsedMs)
    local minutes = elapsedMs / MS_PER_MINUTE
    local players = Core.Player.getPlayers()
    for i = 1, #players do
        local src = players[i]
        local stats = readStats(src)
        if stats then
            local changed, crossed = false, nil
            for name, def in pairs(defs) do
                if def.decayPerMinute > 0 then
                    local old = clampValue(def, stats[name])
                    local new = clampValue(def, old - def.decayPerMinute * minutes)
                    if stats[name] ~= new then
                        stats[name] = new
                        changed = true
                    end
                    if new ~= old then
                        crossed = crossed or {}
                        crossed[#crossed + 1] = { def = def, old = old, new = new }
                    end
                end
            end
            if not changed or writeStats(src, stats) then
                if crossed then
                    markDirty(src)
                    for j = 1, #crossed do
                        local entry = crossed[j]
                        emitThresholds(src, entry.def, entry.old, entry.new)
                    end
                end
            end
        end
    end
end

--- The one decay thread (idempotent). Stopped by `decayRunning` in onResourceStop.
local function startDecay()
    if decayRunning or not enabled() then return false end
    local interval = math.floor(tonumber(Config.Stats.TickMs) or MS_PER_MINUTE)
    if interval < MIN_TICK_MS then interval = MIN_TICK_MS end
    decayRunning = true
    CreateThread(function()
        while decayRunning do
            Wait(interval)
            if not decayRunning then break end
            decayTick(interval)
        end
    end)
    return true
end

-- Definitions from the config (no player is loaded while this file runs, so no backfill pass);
-- plugins add theirs with Stats.define at their own start.
if type(Config.Stats) == 'table' and type(Config.Stats.Defs) == 'table' then
    for name, def in pairs(Config.Stats.Defs) do
        registerDef(name, def)
    end
end

Core.on('playerLoaded', function(src)
    if not enabled() then return end
    initPlayer(src)
end)

Core.on('playerDropped', function(src)
    dirty[src] = nil
    flushPending[src] = nil     -- a scheduled flush still fires but finds nothing dirty
    lastSent[src] = nil
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    decayRunning = false        -- synchronous teardown only (DESIGN §4.9)
end)

Core.Stats = Stats

startDecay()

-- end of file
