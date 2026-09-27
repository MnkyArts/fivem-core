--- core/server/environment.lua — Core.World (time + weather) and Core.Screen (DESIGN §17).
--- The server owns the clock: one 1000 ms thread advances `daySeconds` by Config.World.TimeScale
--- game-seconds per real second and writes GlobalState['core:time'] ONLY when the game minute
--- changes (DESIGN §8 budget: ~1 write every TimeScale-scaled minute, not once per tick).
--- Weather is GlobalState['core:weather']; per-player overrides are targeted events instead of
--- global state, so one player's fog never touches anybody else's bag.
--- The clock, the weather and the cycle position are persisted in the row `world_state` id 1 (DESIGN §56.6),
--- so a core restart resumes the world instead of snapping back to Config.World.StartTime. The row is read ONCE at
--- start (awaited, in onResourceStart); writes are queued saves (never yield): at once for every explicit change
--- (setTime, freezeTime, setWeather) and every weather-cycle step, at most once per real minute for the running
--- clock, and once more when core stops. A READ ERROR at start runs the config defaults and never writes the row
--- until a background re-read works (the stored world is then adopted) or an explicit change is made (it wins).
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
local TABLE <const> = 'world_state'      -- one row, id = 1 (DESIGN §56.6)
local SAVE_EVERY_MS <const> = 60000      -- the running clock: one queued save per real minute at most
local RETRY_MS <const> = 15000           -- re-read of a row that could not be read at start

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
local persistBlocked = false    -- the row could not be READ at start: never overwrite it blindly
local explicitChanges = 0       -- counts setTime / freezeTime / setWeather (an explicit change beats a late read)
local changedDuringRead = nil   -- { time?, frozen?, weather? } while the start read is out (nil otherwise)
local lastSaveAt = 0            -- GetGameTimer() of the last queued save

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

--- The whole world state as one queued save of the row (never yields; the queue coalesces a burst). Skipped while
--- the row could not be read: a blind write would replace the stored world with the defaults.
local function persistState()
    -- while the start read is out nothing is written either: the read waits for the queue (`sync`) and would read
    -- back the defaults instead of the stored world
    if persistBlocked or changedDuringRead then return end
    lastSaveAt = GetGameTimer()
    local ok, err = Core.DB.save(TABLE, {
        id = 1,
        day_seconds = math.floor(daySeconds) % SECONDS_PER_DAY,
        weather = weather,
        frozen = frozen,
        cycle_index = math.floor(cycleIndex),
        cycle_minutes_left = math.max(0, math.floor(cycleMinutesLeft)),
    })
    if not ok then Log.warn('World: could not queue the world state (%s)', tostring(err)) end
end

--- setTime / freezeTime / setWeather: the caller's world is the truth now, even over a row that could not be read.
--- `field` = 'time' | 'frozen' | 'weather': during the start read only that field is kept over the stored row.
local function explicitChange(field)
    explicitChanges = explicitChanges + 1
    if changedDuringRead then changedDuringRead[field] = true end
    if persistBlocked then
        persistBlocked = false
        Log.info('World: an explicit change replaces the world state that could not be read')
    end
end

--- Write GlobalState['core:time'] and fire the timeChanged hook. Called on a minute change,
--- on setTime and on freeze changes — never once per tick.
local function publishTime()
    local h, m, s = timeParts()
    GlobalState['core:time'] = { h = h, m = m, s = s, frozen = frozen }
    lastMinute = h * 60 + m
    Core.emitHook('timeChanged', h, m)
end

--- Write GlobalState['core:weather'] and fire the weatherChanged hook.
local function publishWeather()
    GlobalState['core:weather'] = { type = weather, transition = weatherTransition }
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
    explicitChange('time')
    publishTime()
    persistState()
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
    explicitChange('frozen')
    publishTime()
    persistState()
    return true
end

function World.isTimeFrozen()
    return frozen
end

--------------------------------------------------------------------------------
-- Weather
--------------------------------------------------------------------------------

--- The weather change itself (the cycle uses it too; only World.setWeather counts as an explicit change).
local function applyWeather(weatherType, transitionSec)
    weather = weatherType
    weatherTransition = toTransition(transitionSec, DEFAULT_TRANSITION)
    publishWeather()
end

--- Global weather change; `weatherType` must be one of Config.World.Weathers.
function World.setWeather(weatherType, transitionSec)
    if type(weatherType) ~= 'string' or not WEATHERS[weatherType] then
        Log.error('World.setWeather: unknown weather %s', tostring(weatherType))
        return false
    end
    explicitChange('weather')
    applyWeather(weatherType, transitionSec)
    persistState()
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
            applyWeather(entry.type, toTransition(entry.transition, DEFAULT_TRANSITION))
            return true
        end
    end
    Log.warn('World: WeatherCycle has no usable entry, weather stays manual')
    return false
end

--- `minutes` = in-game minutes since the last publish: the cycle runs on world time, so a
--- 60-minute entry lasts one in-game hour (2 real minutes at the default TimeScale of 30).
--- True when the cycle moved on to its next entry.
local function tickWeatherCycle(minutes)
    if cycleMinutesLeft <= 0 then return false end
    cycleMinutesLeft = cycleMinutesLeft - minutes
    if cycleMinutesLeft <= 0 then return nextCycleEntry() end
    return false
end

--- Resume the weather cycle where the last run left off. False when there is no cycle or the
--- stored position no longer fits the configured one (entries edited between restarts).
local function restoreCycle(stored)
    local cycle = worldCfg.WeatherCycle
    if type(cycle) ~= 'table' or #cycle == 0 then return false end
    local index, left = tonumber(stored.cycle_index), tonumber(stored.cycle_minutes_left)
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
                    -- cycle first, then the save: it must carry the cycle counter of THIS minute. A cycle step
                    -- is saved at once, the running clock once per SAVE_EVERY_MS (a crash loses at most that).
                    local cycled = tickWeatherCycle(advanced)
                    publishTime()
                    if cycled or GetGameTimer() - lastSaveAt >= SAVE_EVERY_MS then persistState() end
                end
            end
        end
    end)
end

--- The stored row over the current state (time, frozen, weather, cycle position). True when the cycle resumed.
local function adopt(stored)
    local seconds = tonumber(stored.day_seconds)
    if seconds and seconds >= 0 and seconds < SECONDS_PER_DAY then
        daySeconds = math.floor(seconds)
        frozen = stored.frozen == true
    end
    if type(stored.weather) == 'string' and WEATHERS[stored.weather] then
        weather = stored.weather
        return restoreCycle(stored)
    end
    return false
end

--- A row that could not be read at start is read again in the background until it answers (the stored world is
--- adopted then) or an explicit change made it moot. Nothing is written meanwhile.
local function retryRead()
    -- one thread per failed start read; it ends with the first answer or an explicit change
    -- fxlint-disable-next-line P004
    CreateThread(function()
        while running and persistBlocked do
            Wait(RETRY_MS)
            if not (running and persistBlocked) then return end
            local before = explicitChanges
            local row, err = Core.DB.first(TABLE, { id = 1 }, { sync = true })
            if not persistBlocked or explicitChanges ~= before then return end
            if row ~= nil or err == nil then
                persistBlocked = false
                if row then
                    adopt(row)
                    weatherTransition = DEFAULT_TRANSITION
                    publishTime()
                    publishWeather()
                end
                persistState()
                Log.info('World: the world state could be read again%s', row and ' and was adopted' or '')
                return
            end
            Log.warn('World: the world state still cannot be read (%s)', tostring(err))
        end
    end)
end

local booted = false

-- Boot: the stored row wins, the config is the fallback for whatever it does not carry. The read yields (the
-- handler runs in its own thread): a field changed explicitly meanwhile (time / freeze / weather) is re-applied
-- over the adopted row, the rest (clock, cycle position) still comes from it.
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

    changedDuringRead = {}
    local row, err = Core.DB.first(TABLE, { id = 1 }, { sync = true })
    local changed = changedDuringRead
    changedDuringRead = nil
    local resumed = false
    if row then
        local kept = { daySeconds = daySeconds, frozen = frozen, weather = weather, transition = weatherTransition }
        resumed = adopt(row)
        if changed.time then daySeconds = kept.daySeconds end
        if changed.frozen then frozen = kept.frozen end
        if changed.weather then weather, weatherTransition = kept.weather, kept.transition end
    elseif err ~= nil and next(changed) == nil then
        persistBlocked = true
        Log.error('World: the world state could not be read (%s) — running the config defaults; the stored row '
            .. 'is kept until it can be read or the world is changed explicitly', tostring(err))
    end
    publishTime()
    publishWeather()
    if not resumed then
        nextCycleEntry()        -- fresh start; a no-op when no cycle is configured (manual weather)
    end
    booted = true
    persistState()              -- the resumed (or first) world; skipped while the row could not be read
    startClock()
    if persistBlocked then retryRead() end     -- after startClock: it runs while `running`
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    running = false             -- synchronous: the clock thread exits on its next wake
    -- the clock since the last save: queued, core_db commits it after core is gone (§56.1)
    if booted then persistState() end
end)

-- end of file
