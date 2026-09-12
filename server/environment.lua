--- core/server/environment.lua — Core.World (time + weather) and Core.Screen (DESIGN §17).
--- The server owns the clock: one 1000 ms thread advances `daySeconds` by Config.World.TimeScale
--- game-seconds per real second and writes GlobalState['core:time'] ONLY when the game minute
--- changes (DESIGN §8 budget: ~1 write every TimeScale-scaled minute, not once per tick).
--- Weather is GlobalState['core:weather']; per-player overrides are targeted events instead of
--- global state, so one player's fog never touches anybody else's bag.
--- The clock, the weather and the cycle position are persisted in DB document 'world'/'state',
--- so a core restart resumes the world instead of snapping back to Config.World.StartTime.
--- No GTA natives here: GetGameTimer (shared) for the tick delta, os.* is server-only and unused.

local Log = Core.Log
local Net = Core.Net

local worldCfg = (type(Config) == 'table' and Config.World) or {}
local TIME_SCALE <const> = math.max(1.0, tonumber(worldCfg.TimeScale) or 30)
local DEFAULT_TRANSITION <const> = 15.0
local MAX_TRANSITION <const> = 300.0
local TICK_MS <const> = 1000
local MAX_SRC <const> = 4096
local SECONDS_PER_DAY <const> = 86400
local DOC_COLLECTION <const> = 'world'   -- persisted world state (DESIGN §4.1 document store)
local DOC_ID <const> = 'state'

--- Weather types are a closed set (Config.World.Weathers, DESIGN §28): a client only ever
--- receives a string that was in this table, so no arbitrary string reaches the natives.
local WEATHERS <const> = {}
do
    local list = type(worldCfg.Weathers) == 'table' and worldCfg.Weathers or { 'CLEAR' }
    for i = 1, #list do
        if type(list[i]) == 'string' then WEATHERS[list[i]] = true end
    end
end

local World = {}
local Screen = {}
Core.World = World
Core.Screen = Screen

local daySeconds = 12 * 3600    -- authoritative float clock, 0..86400
local frozen = false
local weather = 'CLEAR'
local weatherTransition = DEFAULT_TRANSITION
local timeOverride = {}         -- [src] = { h, m }
local weatherOverride = {}      -- [src] = { type, transition }
local lastMinute = -1           -- last published h * 60 + m
local cycleIndex = 0            -- Config.World.WeatherCycle position
local cycleMinutesLeft = 0      -- in-game minutes until the next cycle entry
local running = false

--- h, m, s for the current `daySeconds` (integers, always in range).
local function timeParts()
    local t = math.floor(daySeconds) % SECONDS_PER_DAY
    return t // 3600, (t % 3600) // 60, t % 60
end

--- Player id from an API argument; nil when it is not a plausible server id.
local function toSrc(value)
    if math.type(value) ~= 'integer' then
        if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
        value = math.floor(value)
    end
    if value < 1 or value > MAX_SRC then return nil end
    return value
end

--- Clamp an optional transition time (seconds) coming from a plugin.
local function toTransition(value, fallback)
    if type(value) ~= 'number' or value ~= value then return fallback end
    if value < 0 then return 0.0 end
    if value > MAX_TRANSITION then return MAX_TRANSITION end
    return value + 0.0
end

--- The whole world state in one small document (collection 'world', id 'state'), rewritten on
--- every publish. DB.set only touches memory + a dirty flag; server/db.lua's own 5 s timer does
--- the KVP write. Without this, every core restart snaps the clock back to Config.World.StartTime
--- and replays the weather cycle from its first entry.
local function persistState()
    local db = rawget(Core, 'DB')
    if type(db) ~= 'table' or type(db.set) ~= 'function' then return end
    local ok, err = pcall(db.set, DOC_COLLECTION, DOC_ID, {
        id = DOC_ID,
        daySeconds = math.floor(daySeconds),
        weather = weather,
        frozen = frozen,
        cycleIndex = cycleIndex,
        cycleMinutesLeft = cycleMinutesLeft,
    })
    if not ok then Log.debug('World: could not persist the world state (%s)', tostring(err)) end
end

--- The persisted document, or nil when there is none (first boot, DB unavailable, bad shape).
local function loadState()
    local db = rawget(Core, 'DB')
    if type(db) ~= 'table' or type(db.get) ~= 'function' then return nil end
    local ok, doc = pcall(db.get, DOC_COLLECTION, DOC_ID)
    if not ok or type(doc) ~= 'table' then return nil end
    return doc
end

--- Write GlobalState['core:time'] and fire the timeChanged hook. Called on a minute change,
--- on setTime and on freeze changes — never once per tick.
local function publishTime()
    local h, m, s = timeParts()
    GlobalState['core:time'] = { h = h, m = m, s = s, frozen = frozen }
    lastMinute = h * 60 + m
    persistState()
    Core.emitHook('timeChanged', h, m)
end

--- Write GlobalState['core:weather'] and fire the weatherChanged hook.
local function publishWeather()
    GlobalState['core:weather'] = { type = weather, transition = weatherTransition }
    persistState()
    Core.emitHook('weatherChanged', weather)
end

--- Hour/minute/second argument -> integer in 0..max, or nil when the caller passed junk.
local function toClockUnit(value, max)
    if math.type(value) ~= 'integer' then
        if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
        value = math.floor(value)
    end
    if value < 0 or value > max then return nil end
    return value
end

--------------------------------------------------------------------------------
-- Time
--------------------------------------------------------------------------------

--- Jump the global clock. Publishes right away instead of waiting for the next minute tick.
function World.setTime(hour, minute, second)
    local h = toClockUnit(hour, 23)
    local m = toClockUnit(minute, 59)
    local s = second == nil and 0 or toClockUnit(second, 59)
    if not h or not m or not s then
        Log.error('World.setTime: invalid time %s:%s:%s', tostring(hour), tostring(minute), tostring(second))
        return false
    end
    daySeconds = h * 3600 + m * 60 + s
    publishTime()
    return true
end

--- @return integer h, integer m, integer s
function World.getTime()
    return timeParts()
end

--- Stop/resume the clock. Frozen time keeps ticking on the client unless it is re-applied,
--- so the flag travels in the same state value and the client thread re-applies it.
function World.freezeTime(value)
    if type(value) ~= 'boolean' then
        Log.error('World.freezeTime: expected boolean, got %s', type(value))
        return false
    end
    frozen = value
    publishTime()
    return true
end

function World.isTimeFrozen()
    return frozen
end

--------------------------------------------------------------------------------
-- Weather
--------------------------------------------------------------------------------

--- Global weather change; `weatherType` must be one of Config.World.Weathers.
function World.setWeather(weatherType, transitionSec)
    if type(weatherType) ~= 'string' or not WEATHERS[weatherType] then
        Log.error('World.setWeather: unknown weather %s', tostring(weatherType))
        return false
    end
    weather = weatherType
    weatherTransition = toTransition(transitionSec, DEFAULT_TRANSITION)
    publishWeather()
    return true
end

function World.getWeather()
    return weather
end

--------------------------------------------------------------------------------
-- Per-player overrides (targeted events, never global state)
--------------------------------------------------------------------------------

function World.setTimeFor(src, hour, minute)
    local target = toSrc(src)
    local h = toClockUnit(hour, 23)
    local m = toClockUnit(minute, 59)
    if not target or not h or not m then
        Log.error('World.setTimeFor: invalid arguments (%s, %s, %s)', tostring(src), tostring(hour), tostring(minute))
        return false
    end
    timeOverride[target] = { h = h, m = m }
    Net.emit(target, 'core:client:timeOverride', h, m)
    return true
end

function World.clearTimeFor(src)
    local target = toSrc(src)
    if not target then return false end
    timeOverride[target] = nil
    Net.emit(target, 'core:client:timeOverride', false)
    return true
end

function World.setWeatherFor(src, weatherType, transitionSec)
    local target = toSrc(src)
    if not target or type(weatherType) ~= 'string' or not WEATHERS[weatherType] then
        Log.error('World.setWeatherFor: invalid arguments (%s, %s)', tostring(src), tostring(weatherType))
        return false
    end
    local transition = toTransition(transitionSec, DEFAULT_TRANSITION)
    weatherOverride[target] = { type = weatherType, transition = transition }
    Net.emit(target, 'core:client:weatherOverride', weatherType, transition)
    return true
end

function World.clearWeatherFor(src)
    local target = toSrc(src)
    if not target then return false end
    weatherOverride[target] = nil
    Net.emit(target, 'core:client:weatherOverride', false)
    return true
end

-- Per-player tables never outlive the player (rulebook §9).
AddEventHandler('playerDropped', function()
    local src = source
    timeOverride[src] = nil
    weatherOverride[src] = nil
end)

--------------------------------------------------------------------------------
-- Core.Screen — one targeted event per op, applied by client/environment.lua
--------------------------------------------------------------------------------

local NAME_PATTERN <const> = '^[%w_%-%.]+$'
local MAX_NAME <const> = 64
local MAX_EFFECT_MS <const> = 600000

--- Effect / timecycle names reach a native on the client: keep them to a sane character set.
local function toName(value)
    if type(value) ~= 'string' or #value == 0 or #value > MAX_NAME then return nil end
    if not value:match(NAME_PATTERN) then return nil end
    return value
end

--- Milliseconds argument -> integer 0..max.
local function toMs(value, fallback, max)
    if value == nil then return fallback end
    if type(value) ~= 'number' or value ~= value then return nil end
    local ms = math.floor(value)
    if ms < 0 or ms > max then return nil end
    return ms
end

local function sendScreen(op, src, ...)
    local target = toSrc(src)
    if not target then
        Log.error('Screen.%s: invalid src %s', op, tostring(src))
        return false
    end
    Net.emit(target, 'core:client:screen', op, ...)
    return true
end

--- fade/unfade/blur/unblur all carry a single duration; one helper, four thin wrappers.
local function screenDuration(op, src, ms, fallback)
    local duration = toMs(ms, fallback, MAX_EFFECT_MS)
    if not duration then
        Log.error('Screen.%s: invalid duration %s', op, tostring(ms))
        return false
    end
    return sendScreen(op, src, duration)
end

--- Fade to black / back in over `ms` (default 500).
function Screen.fade(src, ms) return screenDuration('fade', src, ms, 500) end
function Screen.unfade(src, ms) return screenDuration('unfade', src, ms, 500) end

--- Screen blur in / out; `ms` becomes the native's float seconds on the client (default 1000).
function Screen.blur(src, ms) return screenDuration('blur', src, ms, 1000) end
function Screen.unblur(src, ms) return screenDuration('unblur', src, ms, 1000) end

--- Play an animpostfx (screen effect). duration 0 + looped = until cleared.
function Screen.effect(src, name, durationMs, looped)
    local effect = toName(name)
    local duration = toMs(durationMs, 0, MAX_EFFECT_MS)
    if not effect or not duration then
        Log.error('Screen.effect: invalid effect %s', tostring(name))
        return false
    end
    return sendScreen('effect', src, effect, duration, looped == true)
end

function Screen.clearEffect(src, name)
    local effect = toName(name)
    if not effect then return false end
    return sendScreen('clearEffect', src, effect)
end

function Screen.clearEffects(src)
    return sendScreen('clearEffects', src)
end

--- Apply a timecycle modifier, optionally with a strength in 0..1.
function Screen.timecycle(src, name, strength)
    local modifier = toName(name)
    if not modifier then
        Log.error('Screen.timecycle: invalid modifier %s', tostring(name))
        return false
    end
    local value
    if strength ~= nil then
        if type(strength) ~= 'number' or strength ~= strength then return false end
        value = math.min(math.max(strength, 0.0), 1.0) + 0.0
    end
    return sendScreen('timecycle', src, modifier, value)
end

function Screen.clearTimecycle(src)
    return sendScreen('clearTimecycle', src)
end

--------------------------------------------------------------------------------
-- Clock thread, weather cycle, lifecycle
--------------------------------------------------------------------------------

--- Apply the next entry of Config.World.WeatherCycle; false when no cycle is configured.
local function nextCycleEntry()
    local cycle = worldCfg.WeatherCycle
    if type(cycle) ~= 'table' or #cycle == 0 then return false end
    for _ = 1, #cycle do
        cycleIndex = cycleIndex % #cycle + 1
        local entry = cycle[cycleIndex]
        if type(entry) == 'table' and type(entry.type) == 'string' and WEATHERS[entry.type] then
            cycleMinutesLeft = math.max(1, math.floor(tonumber(entry.minutes) or 60))
            World.setWeather(entry.type, toTransition(entry.transition, DEFAULT_TRANSITION))
            return true
        end
    end
    Log.warn('World: WeatherCycle has no usable entry, weather stays manual')
    return false
end

--- `minutes` = in-game minutes since the last publish: the cycle runs on world time, so a
--- 60-minute entry lasts one in-game hour (2 real minutes at the default TimeScale of 30).
local function tickWeatherCycle(minutes)
    if cycleMinutesLeft <= 0 then return end
    cycleMinutesLeft = cycleMinutesLeft - minutes
    if cycleMinutesLeft <= 0 then nextCycleEntry() end
end

--- Resume the weather cycle where the last run left off. False when there is no cycle or the
--- stored position no longer fits the configured one (entries edited between restarts).
local function restoreCycle(stored)
    local cycle = worldCfg.WeatherCycle
    if type(cycle) ~= 'table' or #cycle == 0 then return false end
    local index, left = tonumber(stored.cycleIndex), tonumber(stored.cycleMinutesLeft)
    if not index or not left or index % 1 ~= 0 or index < 1 or index > #cycle or left <= 0 then
        return false
    end
    cycleIndex, cycleMinutesLeft = math.floor(index), math.floor(left)
    return true
end

--- The one clock thread: wakes every second, writes GlobalState only on a minute change.
local function startClock()
    if running then return end
    running = true
    CreateThread(function()
        local last = GetGameTimer()
        while running do
            Wait(TICK_MS)
            local now = GetGameTimer()
            local elapsed = now - last
            last = now
            if not frozen and elapsed > 0 then
                daySeconds = (daySeconds + (elapsed / 1000) * TIME_SCALE) % SECONDS_PER_DAY
                local h, m = timeParts()
                local minute = h * 60 + m
                if minute ~= lastMinute then
                    -- A backwards World.setTime (or a midnight wrap) must not hand the cycle a
                    -- whole day's worth of minutes: only a small forward step counts as elapsed.
                    local delta = minute - lastMinute
                    local advanced = (delta > 0 and delta < 60) and delta or 1
                    -- cycle first, publish second: publishTime persists the world state, and it
                    -- must carry the cycle counter of THIS minute, not the previous one.
                    tickWeatherCycle(advanced)
                    publishTime()
                end
            end
        end
    end)
end

-- Boot: the persisted state wins, the config is the fallback for whatever it does not carry.
AddEventHandler('onResourceStart', function(resource)
    if resource ~= Core.name then return end
    local startTime = type(worldCfg.StartTime) == 'table' and worldCfg.StartTime or nil
    local h = (startTime and toClockUnit(startTime[1], 23)) or 12
    local m = (startTime and toClockUnit(startTime[2], 59)) or 0
    local default = worldCfg.DefaultWeather
    daySeconds = h * 3600 + m * 60
    weather = (type(default) == 'string' and WEATHERS[default]) and default or 'CLEAR'
    frozen = false
    weatherTransition = 0.0     -- first publish: players join straight into the current weather

    local stored, resumed = loadState(), false
    if stored then
        local seconds = tonumber(stored.daySeconds)
        if seconds and seconds >= 0 and seconds < SECONDS_PER_DAY then
            daySeconds = math.floor(seconds)
            frozen = stored.frozen == true
        end
        if type(stored.weather) == 'string' and WEATHERS[stored.weather] then
            weather = stored.weather
            resumed = restoreCycle(stored)
        end
    end
    publishTime()
    publishWeather()
    if not resumed then
        nextCycleEntry()        -- fresh start; a no-op when no cycle is configured (manual weather)
    end
    startClock()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    running = false             -- synchronous: the clock thread exits on its next wake
end)

-- end of file
